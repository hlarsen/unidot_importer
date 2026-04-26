# Creates Godot materials from Unity materials.
#
# In Godot, materials and shaders are decoupled:
# - StandardMaterial3D (built-in shading model)
# - ShaderMaterial (custom shader-driven)
#
# In Unity, materials and shaders are tightly coupled:
# shaders define the available properties, and materials store values for them.
#
# Unity has multiple render pipelines (Built-in, URP, HDRP), but we do not need to explicitly handle
# pipeline selection here because the exported material already contains resolved shader + property data.
# The .mat file serializes the shader reference (by GUID) and resolved property values directly.
# Texture references are stored as GUIDs and must be resolved separately via the asset database.
#
# The conversion process is:
# 1. Detect the Unity shader used by the material
# 2. Interpret its property schema (and keywords)
# 3. Map those properties to equivalent Godot material fields
class_name UnidotMaterial extends UnidotObject

const asset_database_class := preload("../../asset_database.gd")
const UNITY_PROPERTY_GROUPS := {
	"floats": "m_Floats",
	"colors": "m_Colors",
	"textures": "m_TexEnvs",
}

var ALBEDO_NAMES: Array[String] = ["_Albedo_Map", "_MainTex", "_BaseColorMap"]
var NORMAL_NAMES: Array[String] = ["_Normal_Map", "_BumpMap", "_NormalMap"]

func get_godot_extension() -> String:
	return ".mat.tres"

func get_godot_type() -> String:
	return "StandardMaterial3D"

# TODO: review and implement (whatever we can) from the Godot 4 StandardMaterial3D setup
# we have the inspector option names commented out inline with the ones we're actively using
# these docs are now kind of old... looking at Unity and the Materials/Shaders themselves now
# we have more to go through and will add some other good ones
# https://github.com/Unity-Technologies/UnityCsReference/blob/master/Editor/Mono/Inspector/StandardShaderGUI.cs
func create_godot_resource() -> Resource:  #Material:
	var unity_material_data: Dictionary = _parse_unity_material()
	var keywords: Dictionary = unity_material_data["keywords"]
	var textures: Dictionary = unity_material_data["textures"]
	var floats: Dictionary = unity_material_data["floats"]
	var colors: Dictionary = unity_material_data["colors"]

	print("\nCreating material: " + self.name)
	var mat: StandardMaterial3D = null
	if unity_material_data["shader_name"].to_lower().ends_with(".shadergraph"):
		print("Processing material with ShaderGraph %s" % unity_material_data["shader_name"])
		mat = _create_shadergraph_material(keywords, textures, floats, colors)
	else:
		print("Processing material with Shader %s" % unity_material_data["shader_name"])
		mat = _create_standard_shader_material(keywords, textures, floats, colors)

	assign_object_meta(mat)

	# NOTE: should we look at the built-in meta, unidot_keys?
	mat.set_meta("converted_via_unidot", {
		"notes": "",
		"unity_data": unity_material_data,
	})

	return mat

# this is called by asset_adapter
func bake_roughness_texture_if_needed(tmp_path: String, guid_to_pkgasset: Dictionary, stage2_dict_lock: Mutex, stage2_extra_asset_dict: Dictionary) -> String:
	var kws: Dictionary = _get_keywords()
	var floats: Dictionary = _get_saved_properties(UNITY_PROPERTY_GROUPS.floats)
	var textures: Dictionary = _parse_textures(keys.get("m_SavedProperties", {}))

	var glossiness_value: float = floats.get("_GlossMapScale", 1.0)
	if is_equal_approx(glossiness_value, 0.0):
		log_debug("Material has 0 _GlossMapScale")
		return ""

	var metallic_gloss_texture_ref: Dictionary = textures.get("_MetallicGlossMap", {})
	var raw_ref: Array = []

	if metallic_gloss_texture_ref.has("guid") and metallic_gloss_texture_ref["guid"] != "":
		raw_ref = [metallic_gloss_texture_ref["file_id"], metallic_gloss_texture_ref["local_id"], metallic_gloss_texture_ref["guid"], 0]

	if raw_ref.is_empty() or raw_ref[1] == 0:
		log_debug("Material has null _MetallicGlossMap")
		return ""

	log_debug("gloss map ref is " + str(raw_ref))

	var target_meta: Object
	if guid_to_pkgasset.has(raw_ref[2]):
		target_meta = guid_to_pkgasset[raw_ref[2]].parsed_meta
	else:
		target_meta = meta.lookup_meta(raw_ref)

	if target_meta == null:
		log_warn("Failed to lookup gloss texture ref", "_MetallicGlossMap", raw_ref)
		return ""

	target_meta.mutex.lock()

	var pathname: String = target_meta.path
	var roughness_filename: String = pathname.get_basename() + ".roughness.png"

	stage2_dict_lock.lock()
	if stage2_extra_asset_dict.has(roughness_filename):
		stage2_dict_lock.unlock()
		target_meta.mutex.unlock()
		return ""

	stage2_extra_asset_dict[roughness_filename] = true
	stage2_dict_lock.unlock()

	var ret: String = _bake_roughness_texture_locked(tmp_path, target_meta, roughness_filename, glossiness_value, guid_to_pkgasset)
	target_meta.mutex.unlock()
	return ret

func _bake_roughness_texture_locked(tmp_path: String, target_meta: Object, roughness_filename: String, glossiness_value: float, guid_to_pkgasset: Dictionary) -> String:
	var pathname: String = target_meta.path
	if FileAccess.file_exists(roughness_filename):
		var fa := FileAccess.open(roughness_filename, FileAccess.READ)
		if fa != null:
			if fa.get_length() > 0:
				if not target_meta.godot_resources.has(-target_meta.main_object_id):
					target_meta.insert_resource_path(-target_meta.main_object_id, "res://" + roughness_filename)
				log_debug("Roughness texture already exists. Modified " + str(target_meta.guid) + "/" + str(target_meta.path) + " godot_resources: " + str(target_meta.godot_resources))
				return "" # Nothing new to import.
	var image: Image
	if FileAccess.file_exists(tmp_path + "/" + pathname):
		image = Image.load_from_file(tmp_path + "/" + pathname)
	elif FileAccess.file_exists(pathname):
		image = Image.load_from_file(pathname)
	if image != null:
		log_debug("Texture " + str(pathname) + " exists. Loaded " + str(image))
		if image != null and image.get_width() > 0 and image.get_height() > 0:
			if not meta.internal_data.has("extra_textures"):
				meta.internal_data["extra_textures"] = {}
			meta.internal_data["extra_textures"][roughness_filename] = {
				"temp_path": tmp_path + "/" + roughness_filename,
				"source_meta_guid": target_meta.guid,
				"roughness/mode": 5,
			}
			if not FileAccess.file_exists(roughness_filename + ".import"):
				var cfile: ConfigFile = ConfigFile.new()
				cfile.set_value("remap", "path", "unidot_default_remap_path")  # must be non-empty. hopefully ignored.
				# Make an empty "keep" importer file so it will not be imported.
				cfile.set_value("remap", "importer", "keep")
				cfile.save("res://" + roughness_filename + ".import")
				log_debug("Generated dummy roughness " + str(roughness_filename))
			if not FileAccess.file_exists(roughness_filename):
				# Make an empty file so it will be found by a scan!
				var f: FileAccess = FileAccess.open(roughness_filename, FileAccess.WRITE_READ)
				f.close()
				f = null
			else:
				log_debug("Already existing roughness " + str(roughness_filename))
			var col: Color
			for x in range(image.get_width()):
				for y in range(image.get_height()):
					col = image.get_pixel(x, y)
					col.a = 1.0 - glossiness_value * col.a
					image.set_pixel(x, y, col)
			image.save_png(tmp_path + "/" + roughness_filename)
			target_meta.insert_resource_path(-target_meta.main_object_id, "res://" + roughness_filename)
			log_debug("Roughness texture modified " + str(target_meta.guid) + "/" + str(target_meta.path) + " godot_resources: " + str(target_meta.godot_resources))
			log_debug("Generated " + str(tmp_path) + "/" + str(roughness_filename) + " " + str(image.get_size()))
			return roughness_filename
	# TODO: Glossiness: invert color channels??
	log_warn("Failed to generate roughness texture at " + str(pathname) + " from " + str(target_meta.guid), "_MetallicGlossMap", [null, target_meta.main_object_id, target_meta.guid, 0])
	return ""

func _get_keywords() -> Dictionary:
	var ret: Dictionary = {}

	var kwd = keys.get("m_ShaderKeywords", "")
	if typeof(kwd) == TYPE_STRING:
		for x in kwd.split(" "):
			ret[x] = true

	var validkws: Array = keys.get("m_ValidKeywords", [])
	for x in validkws:
		ret[str(x)] = true

	# do we want these? they're from a previous shader, not the current one?
#	var invalidkws: Array = keys.get("m_InvalidKeywords", [])
#	for x in invalidkws:
#		# Keywords from before the material was switched to another shader.
#		# Since we don't parse shaders, this will sometimes give the equivalent Standard shader keywords.
#		ret[str(x)] = true

	return ret

func _get_shader_base_filename() -> String:
	var shader_data = keys.get("m_Shader", [])
	var shader_guid = shader_data[2] if shader_data.size() > 2 else null
	if not shader_guid:
		return ""

#	print("This material is using a Unity Shader: %s" % shader_data)
	var asset_database: asset_database_class = asset_database_class.new().get_singleton()
	var asset_path: String = asset_database.guid_to_asset_path(shader_guid)
#	print("Unity Shader Filename: %s" % asset_path.get_file())

	return asset_path.get_file()

func _parse_unity_material() -> Dictionary:
	return {
		"shader_name": _get_shader_base_filename(),
		"keywords": _get_keywords(),
		"textures": _parse_textures(keys.get("m_SavedProperties", {})),
		"floats": _get_saved_properties(UNITY_PROPERTY_GROUPS.floats),
		"colors": _get_saved_properties(UNITY_PROPERTY_GROUPS.colors),
	}

func _get_saved_properties(group_key: String) -> Dictionary:
	var items: Array = keys.get("m_SavedProperties", {}).get(group_key, [])
	var ret: Dictionary = {}

	for entry in items:
		if entry.has("first") and entry.has("second"):
			ret[entry["first"]["name"]] = entry["second"]
		else:
			ret.merge(entry)

	return ret

func _normalize_texture_ref(raw: Array) -> Dictionary:
	if raw.is_empty():
		return {
			"file_id": 0,
			"local_id": 0,
			"guid": "",
			"type": 0
		}

	return {
		"file_id": raw[0],
		"local_id": raw[1],
		"guid": raw[2],
		"type": raw[3]
	}

func _parse_textures(saved_properties: Dictionary) -> Dictionary:
	var ret: Dictionary = {}

	var tex_list: Array = saved_properties.get("m_TexEnvs", [])

	for entry in tex_list:
		var name: String
		var env: Dictionary

		if entry.has("first") and entry.has("second"):
			name = entry["first"]["name"]
			env = entry["second"]
		else:
			name = entry.keys()[0]
			env = entry[name]

		var raw_ref: Array = env.get("m_Texture", [])
		var ref := _normalize_texture_ref(raw_ref)

#		# skip empty textures
#		if ref.guid == "":
#			continue

		var texture: Texture = null
		if ref.guid != "":
			texture = meta.get_godot_resource(raw_ref)

		ret[name] = {
			"guid": ref.guid,
			"file_id": ref.file_id,
			"local_id": ref.local_id,
			"texture": texture,
			"scale": env.get("m_Scale", Vector2.ONE),
			"offset": env.get("m_Offset", Vector2.ZERO),
		}

	return ret

func _get_first_texture(textures: Dictionary, names: Array[String]) -> Dictionary:
	for n in names:
		if textures.has(n):
			var entry: Dictionary = textures[n]
			if entry.get("texture", null) != null:
				return entry
	return {}

func _create_standard_shader_material(keywords: Dictionary, textures: Dictionary, floats: Dictionary, colors: Dictionary) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.resource_name = self.name

	# transparency (default is Unity rendering mode Opaque)
	if keywords.has("_ALPHATEST_ON"):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		var cutoff: float = floats.get("_Cutoff", 0.0)
		if cutoff > 0.0:
			mat.alpha_scissor_threshold = cutoff

	if keywords.has("_ALPHABLEND_ON"):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	if keywords.has("_ALPHAPREMULTIPLY_ON"):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_PREMULT_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# shading
	if keywords.has("_SPECULARHIGHLIGHTS_OFF"):
		mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	if keywords.has("_DOUBLESIDED_ON"):
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# vertex color
	# use as albedo, is sRGB

	# albedo
	mat.albedo_color = colors.get("_Color", Color.WHITE)
	var albedo_entry: Dictionary = _get_first_texture(textures, ALBEDO_NAMES)
	var albedo_tex: Texture = albedo_entry.get("texture", null)
	if albedo_tex:
		mat.albedo_texture = albedo_tex

	# metallic / roughness
	# Unity handles metallic and specular differently than Godot so we have to get fancy
	# set some defaults that apply to Unity's specular/metallic/dielectric modes
	mat.metallic = 0.0
	mat.metallic_specular = 0.0
	mat.roughness = 0.0
	mat.roughness_texture_channel = int(floats.get("_SmoothnessTextureChannel", 0.0))

	# smoothness changes from a value to a scale when:
	# we set a Metallic/Specular texture OR when Source is changes from Metallic Alpha to Albedo Alpha
	# so when it deals with a texture i guess...
	if keywords.has("_METALLICGLOSSMAP"):
		var spec_color = floats.get("_SpecColor", null)

		if textures.has("_SpecGlossMap") and spec_color != null:
			# specular mode - Unity Standard (Specular setup)
			mat.metallic_specular = floats.get("_SpecColor", 0.0)

			var spec_tex = textures.get("_SpecGlossMap", {}).get("texture", null)
			if spec_tex:
				mat.metallic_texture = spec_tex
				# TODO: Unity can use specular or albedo alpha; can't find Source property
				mat.roughness = 1.0 - floats.get("_GlossMapScale", 0.0)
				mat.roughness_texture = spec_tex

		elif textures.has("_MetallicGlossMap") and floats.has("_Metallic"):
			# metallic mode - Unity Standard
			mat.metallic = floats.get("_Metallic", 0.0)

			var metallic_tex = textures.get("_MetallicGlossMap", {}).get("texture", null)
			if metallic_tex:
				mat.metallic_texture = metallic_tex
				mat.roughness = 1.0 - floats.get("_GlossMapScale", 0.0)
				mat.roughness_texture = metallic_tex
	else:
		# dielectric mode - works with either Standard or Standard (Specular setup) i guess
		mat.metallic = floats.get("_Metallic", 0.0)
		mat.metallic_specular = floats.get("_SpecColor", 0.0)
		mat.roughness = 1.0 - floats.get("_Glossiness", 0.0)

	# emission
	if keywords.has("_EMISSION"):
		# NOTE: i don't think emission uses the alpha channel so this should be fine
		# it appears Unity uses it for emission intensity
		mat.emission = colors.get("_EmissionColor", Color.BLACK).linear_to_srgb()
		mat.emission_energy = mat.emission.a
		mat.emission_enabled = true

		var emission_tex = textures.get("_EmissionMap", {}).get("texture", null)
		if emission_tex:
			mat.emission_texture = emission_tex
			mat.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY

	# normal map
	if keywords.has("_NORMALMAP"):
		var normal_entry: Dictionary = _get_first_texture(textures, NORMAL_NAMES)
		var normal_map: Texture = normal_entry.get("texture", null)
		if normal_map:
			mat.normal_enabled = true
			mat.normal_texture = normal_map
			mat.normal_scale = floats.get("_BumpScale", 1.0)

	# ambient occlusion
	var occlusion = textures.get("_OcclusionMap", {}).get("texture", null)
	if occlusion:
		mat.ao_texture = occlusion
		mat.ao_enabled = true
		mat.ao_light_affect = floats.get("_OcclusionStrength", 1.0)
		mat.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN

	# height
	if keywords.has("_PARALLAXMAP"):
		var height_map = textures.get("_ParallaxMap", {}).get("texture", null)
		if height_map:
			mat.heightmap_texture = height_map
			mat.heightmap_enabled = true
			mat.heightmap_scale = floats.get("_Parallax", 1.0)

	# detail
	# mask, blend mode, uv layer, albedo tex, normal tex
	if keywords.has("_DetailNormalMap"):
		pass
	if keywords.has("_DetailAlbedoMap"):
		pass

	# uv1
	# NOTE: "In Unity the _MainText scale ... is actually used for all the texture slots other than detail. Godot
	# locks the detail texture to the UV2 slot, while Unity can reuse the main UV slot with a different scale.
	# There's no exact way to replicate the uv2 scale/offset in godot to do this."

	# uv1
	if mat.albedo_texture:
		var tex_scale: Vector2 = albedo_entry.get("scale", Vector2.ONE)
		var tex_offset: Vector2 = albedo_entry.get("offset", Vector2.ZERO)
		mat.uv1_scale = Vector3(tex_scale.x, tex_scale.y, 1.0)
		mat.uv1_offset = Vector3(tex_offset.x, tex_offset.y, 0.0)

	return mat

# NOTE: we're basing this on the Synty Generic_Basic ShaderGraph Shader
# we will likely want to genericize it
func _create_shadergraph_material(keywords: Dictionary, textures: Dictionary, floats: Dictionary, colors: Dictionary) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.resource_name = self.name

	# `Surface Options` Section

	# NOTE: not sure we need this, I believe Godot doesn't make a distinction (but we may need it for options)
	# Workflow Mode: 0=Specular, 1=Metallic; adds _SPECULAR_SETUP keyword  
#	var workflow_mode: int = int(floats.get("_WorkflowMode", 0))
#	var workflow_specular: bool = int(floats.get("_WorkflowMode", 1.0)) == 0

	# Surface Type: 0=Opaque, 1=Transparent; adds BlendMode, some BlendModes have a Preserve Specular Lighting checkbox
	var surface_type: int = int(floats.get("_Surface", 0))
	if surface_type == 1:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		# TODO: _BlendModePreserveSpecular has no StandardMaterial3D equivalent
		match int(floats.get("_Blend", 0)):
			# Blend Mode Alpha: adds _ALPHAPREMULTIPLY_ON and _SURFACE_TYPE_TRANSPARENT keywords, disableshaderpasses DepthOnly
			# m_CustomRenderQueue: 3000, _AlphaToMask: 0, _Blend: 0, _DstBlend: 10, _SrcBlend: 5, _Surface: 1, _ZWrite: 0
			# _BlendModePreserveSpecular checkbox 0/1
			0: mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
			# Blend Mode Premultiply: adds _SURFACE_TYPE_TRANSPARENT keywords, disableshaderpasses DepthOnly
			# m_CustomRenderQueue: 3000, _AlphaToMask: 0, _Blend: 1, _DstBlend: 10, _Surface: 1, _ZWrite: 0
			1: mat.blend_mode = BaseMaterial3D.BLEND_MODE_PREMULT_ALPHA
			# Blend Mode Additive: adds _ALPHAPREMULTIPLY_ON and _SURFACE_TYPE_TRANSPARENT keywords, disableshaderpasses DepthOnly
			# m_CustomRenderQueue: 3000, _AlphaToMask: 0, _Blend: 2, _DstBlend: 1, _Surface: 1, _ZWrite: 0
			# _BlendModePreserveSpecular checkbox 0/1
			2: mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			# Blend Mode Multiply: adds _ALPHAMODULATE_ON and _SURFACE_TYPE_TRANSPARENT keywords, disableshaderpasses DepthOnly
			# m_CustomRenderQueue: 3000, _AlphaToMask: 0, _Blend: 3, _SrcBlend: 2, _Surface: 1, _ZWrite: 0
			3: mat.blend_mode = BaseMaterial3D.BLEND_MODE_MUL

	# Render Face
	var cull: int = int(floats.get("_Cull", 2))
	match cull:
		# Both
		0: mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		# Back
		1: mat.cull_mode = BaseMaterial3D.CULL_FRONT
		# Front
		2: mat.cull_mode = BaseMaterial3D.CULL_BACK

	# Depth Write
	# I think _ZWrite isn't set directly, just by _ZWriteControl
	var depth_write: int = int(floats.get("_ZWriteControl", 0))
	mat.depth_draw_mode = 1
	match depth_write:
		# Auto
		0: mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
		# ForceEnabled
		1: mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
		# ForceDisabled; forces _ZWrite 0 and adds DepthOnly to disabledShaderPasses
		2: mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

	# NOTE: not sure this is supported in Godot
	# Depth Test
#	var depth_test: int = int(floats.get("_ZTest", 4))
#	match depth_test:
##		0: pass # no zero value?
#		1: pass # Never
#		2: pass # Less
#		3: pass # Equal
#		4: pass # LEqual
#		5: pass # Greater
#		6: pass # NotEqual
#		7: pass # GEqual
#		8: pass # Always

	# Alpha Clipping: On/Off; adds _AlphaClip and _AlphaToMask
	var alpha_clip: bool = int(floats.get("_AlphaClip", 0.0)) == 1
	if alpha_clip:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	var alpha_to_mask: bool = int(floats.get("_AlphaToMask", 0.0)) == 1
	if alpha_to_mask:
		mat.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE

	# Cash Shadows: On/Off; adds SHADOWCASTER to disabledShaderPasses
	# It's on MeshInstance3D < (GeometryInstance3D) so we can't set it on the material
	var cast_shadows: bool = int(floats.get("_CastShadows", 1.0)) == 1
	if not cast_shadows:
#		print_debug("Unity material has _CastShadows=0 but it's handled on the Mesh in Godot")
		pass

	# Receive Shadows: On/Off; adds _RECEIVE_SHADOWS_OFF to keywords
	var receive_shadows: bool = int(floats.get("_ReceiveShadows", 1.0)) == 1
	if not receive_shadows:
		mat.disable_receive_shadows = true

	# `Surface Inputs` Section

	# Alpha Clip Threshold
	mat.alpha_scissor_threshold = floats.get("_Alpha_Clip_Threshold", 0.5)

	# BaseColor
	mat.albedo_color = colors.get("_BaseColor", Color.WHITE)

	# Albedo Map
	var albedo_map: Dictionary = _get_first_texture(textures, ["_Albedo_Map"])
	if albedo_map:
		mat.albedo_texture = albedo_map.get("texture", null)
		# TODO: rename tiling to match Unity?
		# TODO: we're using uv1/uv2 from Albedo texture, but UV1/UV2 are on the StandardMaterial3D itself
		# in unity they appear to be per-albedo/emission/etc texture?
		var alb_scale: Vector2 = albedo_map.get("scale", Vector2.ONE)
		var alb_offset: Vector2 = albedo_map.get("offset", Vector2.ZERO)
		mat.uv1_scale = Vector3(alb_scale.x, alb_scale.y, 1.0)
		mat.uv1_offset = Vector3(alb_offset.x, alb_offset.y, 0.0)

	# Enable Emission
	var enable_emission: bool = int(floats.get("_Enable_Emission", 1.0)) == 1
	mat.emission_enabled = enable_emission

	# Emission Color
	var emission_color: Color = colors.get("_Emission_Color", Color.WHITE)
	mat.emission = Color(emission_color.r, emission_color.g, emission_color.b, 1.0)

	# Emission Map
	var emission_map: Dictionary = _get_first_texture(textures, ["_Emission_Map"])
	if emission_map:
		mat.emission_texture = emission_map.get("texture", null)
		mat.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
		# NOTE: per-texture UV scale/offset for emission not supported; uv1 is shared with albedo

	# Metallic
	mat.metallic = floats.get("_Metallic", 0.0)

	# Roughness (the opposite of Smoothness)
	mat.roughness = 1.0 - floats.get("_Smoothness", 0.2)

	# Normal Map
	var normal_map: Dictionary = _get_first_texture(textures, ["_Normal_Map"])
	if normal_map:
		mat.normal_enabled = true
		mat.normal_texture = normal_map.get("texture", null)

	# Normal Amount
	mat.normal_scale = floats.get("_Normal_Amount", 1.0)
	# TODO: rename tiling to match Unity?
#		var norm_scale: Vector2 = normal_map.get("scale", Vector2.ONE)
#		var norm_offset: Vector2 = normal_map.get("offset", Vector2.ZERO)
#		mat.uv1_scale = Vector3(norm_scale.x, norm_scale.y, 1.0)
#		mat.uv1_offset = Vector3(norm_offset.x, norm_offset.y, 0.0)

	# NOTE: These are part of the Synty Generic_Standard Shader - it's the same as Basic but with these
	# I think we need a Godot shader to make use of these
#	var skin_mask: Dictionary = _get_first_texture(textures, ["_Skin_Mask"])
#	var skin_color = colors.get("_Skin_Color", Color.WHITE) # #FFCCAE00
#	var hair_mask: Dictionary = _get_first_texture(textures, ["_Hair_Mask"])
#	var hair_color = colors.get("_Hair_Color", Color.WHITE) # #4F412D00

	# `Advanced Options` Section

	# Queue Control:
	var queue_control: bool = int(floats.get("_QueueControl", 0)) == 1
	if queue_control:
		# UserOverride
		mat.render_priority = int(floats.get("m_CustomRenderQueue", 0))
	else:
		# Auto uses the Sorting Priority slider
		mat.render_priority = int(floats.get("_QueueOffset", 0))

	# Enable GPU Instancing: m_EnableInstancingVariants 1
	# Not supported by Godot?

	# Double Sided Global Illumination: m_DoubleSidedGI 1
	# Not supported by Godot?

	# Global Illumination: LightMapFlags 4: None, 2: Baked, 1: Relatime (where's 3? setting back to None is 0?)
#	print_debug("Unity material has m_LightmapFlags but it's handled on the Mesh in Godot")

	return mat
