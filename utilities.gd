# Misc utilties that could be useful in a lot of places
# Here for now unless we figure out somewhere better
class_name Utilities

static func pretty_print(obj: Variant, indent: int = 0) -> void:
	var prefix: String = "\t".repeat(indent)
	if typeof(obj) == TYPE_DICTIONARY:
		print(prefix + "{")
		for key in obj.keys():
			var line: String = prefix + "\t" + str(key) + ": "
			var value: Variant = obj[key]
			if typeof(value) in [TYPE_DICTIONARY, TYPE_ARRAY]:
				print(line)
				pretty_print(value, indent + 1)
			else:
				print(line + str(value))
		print(prefix + "}")
	elif typeof(obj) == TYPE_ARRAY:
		print(prefix + "[")
		for item: Variant in obj:
			pretty_print(item, indent + 1)
		print(prefix + "]")
	else:
		print(prefix + str(obj))

static func print_node_hierarchy(node: Node, indent: int = 0) -> void:
	if node == null:
		return
	print("\t".repeat(indent) + node.name + " (" + str(node) + ")")
	for child: Node in node.get_children():
		print_node_hierarchy(child, indent + 1)
