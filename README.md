# Unidot Importer (with changes)

This is a fork of [Unidot Importer](https://github.com/V-Sekai/unidot_importer) with some changes that may or may not
be useful for your workflow.

The `custom` branch is the repo default and includes changes.
The `main` branch tracks upstream.

You can review the upstream README [here](https://github.com/V-Sekai/unidot_importer/blob/main/README.md).

## Notes

Important files:

`convert_scene.gd`: `pack_scene()` is the final stop before saving out files, we use `rework_scene_hierarchy()` to
customize objects before final save.
`object_adapter.gd`: `create_godot_resource()` handles converting materials, we rewrote it 
