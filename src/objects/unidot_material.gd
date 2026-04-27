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
const UNITY_PROPERTY_GROUPS: Dictionary[String, String] = {
	"floats": "m_Floats",
	"colors": "m_Colors",
	"textures": "m_TexEnvs",
}

const BUILTIN_SHADER_GUID: String = "0000000000000000f000000000000000"
const BUILTIN_SHADER_NAMES: Dictionary = {
	6: "Legacy Shaders/VertexLit",
	7: "Legacy Shaders/Diffuse",
	45: "Standard (Specular setup)",
	46: "Standard",
	106: "Skybox/Procedural",
	200: "Legacy Shaders/Particles/Additive",
	202: "Legacy Shaders/Particles/Additive (Soft)",
	203: "Legacy Shaders/Particles/Alpha Blended",
	210: "Particles/Standard Surface",
	211: "Particles/Standard Unlit",
	10752: "Unlit/Texture",
	10753: "Sprites/Default",
	10770: "UI/Default",
	10783: "UI/DefaultETC1",
}

func get_godot_extension() -> String:
	return ".mat.tres"

func get_godot_type() -> String:
	return "StandardMaterial3D"

func create_godot_resource() -> Resource:  #Material:
	print("\nCreating material: " + self.name)
	var mat: StandardMaterial3D = null

	var unity_material_data: Dictionary = _parse_unity_material_data()
	var is_shadergraph: bool = unity_material_data["builtin_shader_name"] == ""
	if is_shadergraph:
		print("Processing Shadergraph %s at %s" % [unity_material_data["shadergraph_name"], unity_material_data["shader_path"]])
		mat = UnidotMaterialConverters.create_shadergraph_material(self.name, unity_material_data)
	else:
		print("Processing Shader %s at %s" % [unity_material_data["builtin_shader_name"], unity_material_data["shader_path"]])
		mat = UnidotMaterialConverters.create_standard_shader_material(self.name, unity_material_data)

	assign_object_meta(mat)

	# NOTE: should we look at the built-in meta, unidot_keys?
	mat.set_meta("converted_via_unidot", {
		"unity_material_data": unity_material_data,
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
		var fa: FileAccess = FileAccess.open(roughness_filename, FileAccess.READ)
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

func _get_shader_asset_path() -> String:
	var shader_data = keys.get("m_Shader", [])
	var shader_guid = shader_data[2] if shader_data.size() > 2 else null
	if not shader_guid:
		return ""

	var asset_database: asset_database_class = asset_database_class.new().get_singleton()
	var asset_path: String = asset_database.guid_to_asset_path(shader_guid)

	return asset_path

func _get_builtin_shader_name() -> String:
	var shader_data = keys.get("m_Shader", [])
	var shader_guid = shader_data[2] if shader_data.size() > 2 else ""
	if shader_guid != BUILTIN_SHADER_GUID:
		return ""

	var file_id: int = int(shader_data[1]) if shader_data.size() > 1 else 0
	if not BUILTIN_SHADER_NAMES.has(file_id):
		print("Unknown builtin shader fileID: %d for material: %s" % [file_id, self.name])

	return BUILTIN_SHADER_NAMES.get(file_id, "BUILTIN_UNKNOWN_%d" % file_id)

func _parse_unity_material_data() -> Dictionary:
	var shader_path: String = _get_shader_asset_path()
	var builtin_shader_name: String = _get_builtin_shader_name()

	var graph: Dictionary = {}
	var shadergraph_name: String = ""

	if builtin_shader_name.is_empty() and not shader_path.is_empty():
		graph = ShaderGraphParser.parse("res://.godot/unidot_temp/" + shader_path)
		ShaderGraphParser.print_summary(graph)
		var internal_path: String = graph.get("path", "")
		if internal_path.is_empty():
			shadergraph_name = shader_path
		else:
			shadergraph_name = "\\".join([internal_path, shader_path.get_file().get_basename()])

	return {
		"shader_path": shader_path,
		"builtin_shader_name": builtin_shader_name,
		"shadergraph_name": shadergraph_name,
		"shadergraph_parsed": graph,
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
		var ref: Dictionary = _normalize_texture_ref(raw_ref)

		var texture: Texture = null
		if ref.guid and ref.guid != "":
			texture = meta.get_godot_resource(raw_ref)
			if not texture:
				print("Could not load texture from ref: %s" % str(raw_ref))

		ret[name] = {
			"guid": ref.guid,
			"file_id": ref.file_id,
			"local_id": ref.local_id,
			"texture": texture,
			"scale": env.get("m_Scale", Vector2.ONE),
			"offset": env.get("m_Offset", Vector2.ZERO),
		}

	return ret

