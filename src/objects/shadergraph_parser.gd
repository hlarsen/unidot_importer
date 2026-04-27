# Parses Unity .shadergraph files into a structured Dictionary.
#
# Usage:
#   var graph: Dictionary = ShaderGraphParser.parse("res://path/to/Shader.shadergraph")
#
# Returns a Dictionary with keys:
#   name         - String, filename without extension
#   path         - String, Unity internal path (e.g. "Synty/Effects")
#   precision    - String, "Float" | "Half" | "Inherit"
#   targets      - Array[Dictionary], one per render pipeline target
#   properties   - Array[Dictionary], exposed shader properties
#   nodes        - Array[Dictionary], all processing nodes
#   edges        - Array[Dictionary], all connections between nodes
#   nodes_by_id  - Dictionary, id -> node dict for quick lookup
#   props_by_id  - Dictionary, id -> property dict for quick lookup
#
# Returns an empty Dictionary if the file cannot be read or parsed.
class_name ShaderGraphParser

const SURFACE_TYPE: Dictionary = {
	0: "Opaque",
	1: "Transparent",
}

const ALPHA_MODE: Dictionary = {
	0: "Alpha",
	1: "Premultiply",
	2: "Additive",
	3: "Multiply",
}

const RENDER_FACE: Dictionary = {
	0: "Front",
	1: "Back",
	2: "Both",
}

const POSITION_SPACE: Dictionary = {
	0: "Object",
	1: "View",
	2: "World",
	3: "Tangent",
	4: "AbsoluteWorld",
}

const PRECISION: Dictionary = {
	0: "Inherit",
	1: "Float",
	2: "Half",
}

const PIPELINE_TYPES: Dictionary = {
	"BuiltInTarget": "BuiltIn",
	"UniversalTarget": "URP",
	"HDRenderPipelineTarget": "HDRP",
}

const TARGET_FULL_TYPES: Array = [
	"UnityEditor.Rendering.BuiltIn.ShaderGraph.BuiltInTarget",
	"UnityEditor.Rendering.Universal.ShaderGraph.UniversalTarget",
	"UnityEditor.Rendering.HighDefinition.ShaderGraph.HDRenderPipelineTarget",
]

const GRAPH_DATA_TYPE: String = "UnityEditor.ShaderGraph.GraphData"

static func parse(file_path: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		push_error("ShaderGraphParser: cannot open file: %s" % file_path)
		return {}

	var content: String = file.get_as_text()
	file.close()

	var objects: Array = _split_objects(content)
	if objects.is_empty():
		push_error("ShaderGraphParser: no objects parsed from: %s" % file_path)
		return {}

	var by_id: Dictionary = {}
	for obj in objects:
		var oid: String = obj.get("m_ObjectId", "")
		if oid != "":
			by_id[oid] = obj

	var graph_obj: Dictionary = {}
	for obj in objects:
		if obj.get("m_Type", "") == GRAPH_DATA_TYPE:
			graph_obj = obj
			break

	if graph_obj.is_empty():
		push_error("ShaderGraphParser: no GraphData found in: %s" % file_path)
		return {}

	var properties: Array = _parse_properties(graph_obj, by_id)
	var props_by_id: Dictionary = {}
	for prop in properties:
		props_by_id[prop["id"]] = prop

	var nodes: Array = _parse_nodes(graph_obj, by_id, props_by_id)
	var nodes_by_id: Dictionary = {}
	for node in nodes:
		nodes_by_id[node["id"]] = node

	return {
		"name": file_path.get_file().get_basename(),
		"path": graph_obj.get("m_Path", ""),
		"precision": PRECISION.get(graph_obj.get("m_GraphPrecision", 0), "Inherit"),
		"targets": _parse_targets(objects),
		"properties": properties,
		"nodes": nodes,
		"edges": _parse_edges(graph_obj),
		"nodes_by_id": nodes_by_id,
		"props_by_id": props_by_id,
	}

static func _split_objects(content: String) -> Array:
	# .shadergraph files are multiple top-level JSON objects concatenated,
	# not a JSON array. Walk by brace depth to find each object boundary.
	var objects: Array = []
	var depth: int = 0
	var start: int = -1
	var in_string: bool = false
	var escape_next: bool = false

	for i in content.length():
		var c: String = content[i]

		if escape_next:
			escape_next = false
			continue

		if c == "\\" and in_string:
			escape_next = true
			continue

		if c == "\"":
			in_string = not in_string
			continue

		if in_string:
			continue

		if c == "{":
			if depth == 0:
				start = i
			depth += 1
		elif c == "}":
			depth -= 1
			if depth == 0 and start != -1:
				var parsed = JSON.parse_string(content.substr(start, i - start + 1))
				if parsed != null:
					objects.append(parsed)
				start = -1

	return objects

static func _parse_properties(graph_obj: Dictionary, by_id: Dictionary) -> Array:
	var result: Array = []

	for ref in graph_obj.get("m_Properties", []):
		var prop_obj: Dictionary = by_id.get(ref.get("m_Id", ""), {})
		if prop_obj.is_empty():
			continue
		result.append(_parse_property(prop_obj))

	return result

static func _parse_property(obj: Dictionary) -> Dictionary:
	var full_type: String = obj.get("m_Type", "")
	var short: String = full_type.split(".")[-1]

	# Value location varies by property type
	var default_value = (
		obj.get("m_Value",
		obj.get("m_FloatValue",
		obj.get("m_ColorValue", null)))
	)

	return {
		"id": obj.get("m_ObjectId", ""),
		"name": obj.get("m_Name", ""),
		"type": short,
		"reference_name": obj.get("m_DefaultReferenceName", ""),
		"default_value": default_value,
		"exposed": obj.get("m_GeneratePropertyBlock", true),
	}

static func _parse_nodes(graph_obj: Dictionary, by_id: Dictionary, props_by_id: Dictionary) -> Array:
	var result: Array = []

	for ref in graph_obj.get("m_Nodes", []):
		var node_obj: Dictionary = by_id.get(ref.get("m_Id", ""), {})
		if node_obj.is_empty():
			continue
		result.append(_parse_node(node_obj, by_id, props_by_id))

	return result

static func _parse_node(obj: Dictionary, by_id: Dictionary, props_by_id: Dictionary) -> Dictionary:
	var full_type: String = obj.get("m_Type", "")
	var short: String = full_type.split(".")[-1]
	var oid: String = obj.get("m_ObjectId", "")

	var node: Dictionary = {
		"id": oid,
		"type": short,
		"name": obj.get("m_Name", short),
		# Extra fields populated below based on type
		"property_id": "",
		"property_name": "",
		"space": "",
		"constant": null,
		"is_output": short == "BlockNode",
	}

	if short == "PropertyNode":
		var prop_id: String = obj.get("m_Property", {}).get("m_Id", "")
		node["property_id"] = prop_id
		node["property_name"] = props_by_id.get(prop_id, {}).get("name", "")

	elif short == "PositionNode":
		node["space"] = POSITION_SPACE.get(obj.get("m_Space", 0), "Object")

	elif short == "Vector3Node":
		node["constant"] = obj.get("m_Value", null)

	elif short == "Vector1Node":
		node["constant"] = obj.get("m_Value", null)

	return node

static func _parse_edges(graph_obj: Dictionary) -> Array:
	var result: Array = []

	for edge in graph_obj.get("m_Edges", []):
		var out_slot: Dictionary = edge.get("m_OutputSlot", {})
		var in_slot: Dictionary = edge.get("m_InputSlot", {})
		result.append({
			"from_node": out_slot.get("m_Node", {}).get("m_Id", ""),
			"from_slot": out_slot.get("m_SlotId", -1),
			"to_node": in_slot.get("m_Node", {}).get("m_Id", ""),
			"to_slot": in_slot.get("m_SlotId", -1),
		})

	return result

static func _parse_targets(objects: Array) -> Array:
	var target_types: Array = TARGET_FULL_TYPES

	var result: Array = []
	for obj in objects:
		if obj.get("m_Type", "") in target_types:
			result.append(_parse_target(obj))

	return result

static func _parse_target(obj: Dictionary) -> Dictionary:
	var full_type: String = obj.get("m_Type", "")
	var short: String = full_type.split(".")[-1]

	return {
		"pipeline": PIPELINE_TYPES.get(short, short),
		"surface_type": SURFACE_TYPE.get(obj.get("m_SurfaceType", 0), "Opaque"),
		"alpha_mode": ALPHA_MODE.get(obj.get("m_AlphaMode", 0), "Alpha"),
		"render_face": RENDER_FACE.get(obj.get("m_RenderFace", 0), "Front"),
		"alpha_clip": obj.get("m_AlphaClip", false),
		"cast_shadows": obj.get("m_CastShadows", null),
		"receive_shadows": obj.get("m_ReceiveShadows", null),
	}

static func print_summary(graph: Dictionary) -> void:
	if graph.is_empty():
		print("ShaderGraphParser: empty graph")
		return

	print("=== ShaderGraph: %s ===" % graph["name"])
	print("  Path:      %s" % graph["path"])
	print("  Precision: %s" % graph["precision"])

	print("\n-- Targets --")
	for t in graph["targets"]:
		print("  %s | %s | %s | alpha_clip=%s" % [
			t["pipeline"], t["surface_type"], t["alpha_mode"], t["alpha_clip"]
		])

	print("\n-- Properties --")
	for p in graph["properties"]:
		print("  %s  (%s)  ref=%s  default=%s" % [
			p["name"], p["type"], p["reference_name"], str(p["default_value"])
		])

	print("\n-- Nodes --")
	for n in graph["nodes"]:
		var label: String = n["type"]
		if n["type"] == "PropertyNode":
			label = "PropertyNode -> '%s'" % n["property_name"]
		elif n["type"] == "PositionNode":
			label = "PositionNode (%s)" % n["space"]
		elif n["type"] == "BlockNode":
			label = "OUTPUT: %s" % n["name"]
		elif n["constant"] != null:
			label = "%s = %s" % [n["type"], str(n["constant"])]
		print("  [%s] %s" % [n["id"].left(8), label])

	print("\n-- Connections --")
	for e in graph["edges"]:
		var src: String = _node_label(e["from_node"], graph)
		var dst: String = _node_label(e["to_node"], graph)
		print("  %s[%d] -> %s[%d]" % [src, e["from_slot"], dst, e["to_slot"]])

	print("\n-- Output Terminals --")
	for n in graph["nodes"]:
		if not n["is_output"]:
			continue
		var sources: Array = []
		for e in graph["edges"]:
			if e["to_node"] == n["id"]:
				sources.append(_node_label(e["from_node"], graph))
		if sources.is_empty():
			print("  %s <- (default)" % n["name"])
		else:
			print("  %s <- %s" % [n["name"], ", ".join(sources)])

static func _node_label(node_id: String, graph: Dictionary) -> String:
	var node: Dictionary = graph["nodes_by_id"].get(node_id, {})
	if node.is_empty():
		return node_id.left(8)
	if node["type"] == "PropertyNode":
		return node["property_name"]
	if node["type"] == "PositionNode":
		return "Position(%s)" % node["space"]
	return node["type"].replace("Node", "")
