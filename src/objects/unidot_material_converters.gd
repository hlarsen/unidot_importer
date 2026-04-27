class_name UnidotMaterialConverters

const ALBEDO_NAMES: Array[String] = ["_Albedo_Map", "_MainTex", "_BaseColorMap"]
const NORMAL_NAMES: Array[String] = ["_Normal_Map", "_BumpMap", "_NormalMap"]

# Creates a Godot material from a Unity material using the Unity Standard shader
# NOTE: Could use another review pass
static func create_standard_shader_material(mat_name: String, unity_material_data: Dictionary) -> StandardMaterial3D:
	var keywords: Dictionary = unity_material_data["keywords"]
	var textures: Dictionary = unity_material_data["textures"]
	var floats: Dictionary = unity_material_data["floats"]
	var colors: Dictionary = unity_material_data["colors"]

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.resource_name = mat_name

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
		mat.uv1_scale = Vector3(tex_scale.x, tex_scale.y, 0.0) # NOTE: Synty Godot projects have this set at 0
		mat.uv1_offset = Vector3(tex_offset.x, tex_offset.y, 0.0)

	return mat

# NOTE: we're basing this on the Synty Generic_Basic ShaderGraph Shader
# we will likely want to genericize it
static func create_shadergraph_material(mat_name: String, unity_material_data: Dictionary) -> StandardMaterial3D:
	var keywords: Dictionary = unity_material_data["keywords"]
	var textures: Dictionary = unity_material_data["textures"]
	var floats: Dictionary = unity_material_data["floats"]
	var colors: Dictionary = unity_material_data["colors"]

	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.resource_name = mat_name

	var shadergraphs_that_should_work: Array = ["Synty\\Generic_Basic", "Synty\\Generic_Standard"]
	if not unity_material_data["shadergraph_name"] in shadergraphs_that_should_work:
		print("Shadergraph processing has not been reviewed for shadergraph %s" % unity_material_data["shadergraph_name"]) 

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

		# NOTE: more options below but glass is one sided unless we do this...
#		mat.cull_mode = BaseMaterial3D.CULL_DISABLED

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

	# TODO: review these - not sure because this is Transparency stuff that overrides previous alpha
	# Alpha Clipping: On/Off; adds _AlphaClip and _AlphaToMask
#	var alpha_clip: bool = int(floats.get("_AlphaClip", 0.0)) == 1
#	if alpha_clip and surface_type == 1:
#		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
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
		mat.uv1_scale = Vector3(alb_scale.x, alb_scale.y, 0.0) # NOTE: Synty Godot projects have this set at 0
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


# Used to look for specific texture key names (good for fallbacks but we're getting pretty specific now)
static func _get_first_texture(textures: Dictionary, names: Array[String]) -> Dictionary:
	for n in names:
		if textures.has(n):
			var entry: Dictionary = textures[n]
			if entry.get("texture", null) != null:
				return entry
	return {}
