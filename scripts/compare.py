#!/usr/bin/env python3
"""Compare two Raftly environment collection runs."""
from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any

NODES = ("node1", "node2", "node3")


def load_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def read_hash(path: Path) -> str | None:
    if not path.is_file():
        return None
    fields = path.read_text(encoding="utf-8").split()
    return fields[0] if fields else None


def image_details(run: Path, node: str) -> dict[str, Any] | None:
    path = run / "nodes" / node / "image-inspect.json"
    if not path.is_file():
        return None
    value = load_json(path)
    return value[0] if isinstance(value, list) else value


def package_list(path: Path) -> set[str] | None:
    if not path.is_file():
        return None
    return {
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    }


def metadata(run: Path) -> dict[str, Any]:
    path = run / "metadata.json"
    if not path.is_file():
        raise SystemExit(f"Missing {path}")
    return load_json(path)


def result_status(run: Path) -> str:
    path = run / "result.json"
    return load_json(path).get("status", "unknown") if path.is_file() else "unknown"


def build_duration(run: Path) -> int | None:
    path = run / "build-duration-seconds.txt"
    return int(path.read_text().strip()) if path.is_file() else None


def input_hashes(run: Path) -> str | None:
    path = run / "input-hashes.txt"
    return path.read_text(encoding="utf-8") if path.is_file() else None


def node_summary(run: Path) -> dict[str, Any]:
    images = [image_details(run, node) for node in NODES]
    images = [image for image in images if image is not None]
    image_ids = [image.get("Id") for image in images]
    layer_lists = [image.get("RootFS", {}).get("Layers", []) for image in images]
    binaries = [read_hash(run / "nodes" / node / "raftly-server.sha256") for node in NODES]
    binaries = [value for value in binaries if value is not None]

    return {
        "nodes_with_image_data": len(images),
        "same_image_id_on_all_nodes": len(image_ids) == len(NODES) and len(set(image_ids)) == 1,
        "same_layers_on_all_nodes": len(layer_lists) == len(NODES) and all(layers == layer_lists[0] for layers in layer_lists),
        "same_raftly_binary_on_all_nodes": len(binaries) == len(NODES) and len(set(binaries)) == 1,
    }


def nix_closure_comparison(run_a: Path, run_b: Path) -> dict[str, Any] | None:
    path_a = run_a / "nix-store-inventory.json"
    path_b = run_b / "nix-store-inventory.json"
    if not path_a.is_file() or not path_b.is_file():
        return None

    rows_a = load_json(path_a)
    rows_b = load_json(path_b)
    store_paths_a = {row.get("store_path", ""): row.get("nar_hash") for row in rows_a}
    store_paths_b = {row.get("store_path", ""): row.get("nar_hash") for row in rows_b}
    objects_a = Counter((row.get("store_name", ""), row.get("nar_hash")) for row in rows_a)
    objects_b = Counter((row.get("store_name", ""), row.get("nar_hash")) for row in rows_b)
    common_paths = set(store_paths_a) & set(store_paths_b)

    return {
        "store_path_count_a": len(store_paths_a),
        "store_path_count_b": len(store_paths_b),
        "same_store_paths": set(store_paths_a) == set(store_paths_b),
        "changed_nar_hash_count": sum(
            store_paths_a[path] != store_paths_b[path] for path in common_paths
        ),
        "added_store_path_count": len(set(store_paths_b) - set(store_paths_a)),
        "removed_store_path_count": len(set(store_paths_a) - set(store_paths_b)),
        "same_store_objects_and_nar_hashes": objects_a == objects_b,
    }


def compare(run_a: Path, run_b: Path) -> dict[str, Any]:
    meta_a, meta_b = metadata(run_a), metadata(run_b)
    same_method = meta_a.get("method") == meta_b.get("method")
    hashes_a, hashes_b = input_hashes(run_a), input_hashes(run_b)

    report: dict[str, Any] = {
        "run_a": str(run_a),
        "run_b": str(run_b),
        "method_a": meta_a.get("method"),
        "method_b": meta_b.get("method"),
        "same_method": same_method,
        "result_a": result_status(run_a),
        "result_b": result_status(run_b),
        "build_duration_seconds_a": build_duration(run_a),
        "build_duration_seconds_b": build_duration(run_b),
        "inputs": {
            "input_hashes_equal": hashes_a == hashes_b if hashes_a is not None and hashes_b is not None else None,
            "docker_base_image_identities_equal": None,
            "tool_versions_equal": meta_a.get("tools") == meta_b.get("tools"),
        },
        "source": {
            "same_experiment_commit": meta_a.get("experiment_repository_commit") == meta_b.get("experiment_repository_commit"),
            "experiment_repo_dirty_a": meta_a.get("experiment_repository_dirty"),
            "experiment_repo_dirty_b": meta_b.get("experiment_repository_dirty"),
            "same_raftly_commit": meta_a.get("raftly_submodule_commit") == meta_b.get("raftly_submodule_commit"),
            "raftly_commit_a": meta_a.get("raftly_submodule_commit"),
            "raftly_commit_b": meta_b.get("raftly_submodule_commit"),
        },
        "nodes_within_run_a": node_summary(run_a),
        "nodes_within_run_b": node_summary(run_b),
        "nodes": {},
    }

    base_a = run_a / "docker-base-image-identities.txt"
    base_b = run_b / "docker-base-image-identities.txt"
    if base_a.is_file() and base_b.is_file():
        report["inputs"]["docker_base_image_identities_equal"] = (
            base_a.read_text(encoding="utf-8") == base_b.read_text(encoding="utf-8")
        )

    for node in NODES:
        image_a = image_details(run_a, node)
        image_b = image_details(run_b, node)
        node_data: dict[str, Any] = {}

        if image_a is not None and image_b is not None:
            node_data["architecture_a"] = image_a.get("Architecture")
            node_data["architecture_b"] = image_b.get("Architecture")
            if same_method:
                node_data["image_id_equal"] = image_a.get("Id") == image_b.get("Id")
                layers_a = image_a.get("RootFS", {}).get("Layers", [])
                layers_b = image_b.get("RootFS", {}).get("Layers", [])
                node_data["layer_diffids_equal"] = layers_a == layers_b
                node_data["layer_count_a"] = len(layers_a)
                node_data["layer_count_b"] = len(layers_b)

        binary_a = read_hash(run_a / "nodes" / node / "raftly-server.sha256")
        binary_b = read_hash(run_b / "nodes" / node / "raftly-server.sha256")
        node_data["raftly_binary_equal"] = (
            binary_a == binary_b if binary_a is not None and binary_b is not None else None
        )

        packages_a = package_list(run_a / "nodes" / node / "apk-packages.txt")
        packages_b = package_list(run_b / "nodes" / node / "apk-packages.txt")
        if same_method and packages_a is not None and packages_b is not None:
            node_data["apk_packages"] = {
                "count_a": len(packages_a),
                "count_b": len(packages_b),
                "added_in_b": sorted(packages_b - packages_a),
                "removed_in_b": sorted(packages_a - packages_b),
                "equal": packages_a == packages_b,
            }
        report["nodes"][node] = node_data

    if same_method:
        closure = nix_closure_comparison(run_a, run_b)
        if closure is not None:
            report["nix_closure"] = closure

    return report


def print_report(report: dict[str, Any]) -> None:
    print("Raftly environment comparison")
    print(f"A: {report['run_a']} ({report['method_a']}, {report['result_a']})")
    print(f"B: {report['run_b']} ({report['method_b']}, {report['result_b']})")
    print(f"Build duration: A={report['build_duration_seconds_a']}s B={report['build_duration_seconds_b']}s")

    inputs = report["inputs"]
    source = report["source"]
    print("\nInputs and source")
    print(f"  Input file hashes equal:     {inputs['input_hashes_equal']}")
    print(f"  Base image identities equal: {inputs['docker_base_image_identities_equal']}")
    print(f"  Tool versions equal:          {inputs['tool_versions_equal']}")
    print(f"  Same experiment commit:       {source['same_experiment_commit']}")
    print(f"  Experiment tree dirty:        A={source['experiment_repo_dirty_a']} B={source['experiment_repo_dirty_b']}")
    print(f"  Same Raftly source commit:    {source['same_raftly_commit']}")

    if not report["same_method"]:
        print("\nDifferent build methods: image IDs and Nix NAR hashes are not directly comparable.")
        print("The Raftly executable SHA-256 is the direct byte-level comparison.")

    print("\nNode consistency within each run")
    for label in ("a", "b"):
        summary = report[f"nodes_within_run_{label}"]
        print(f"  Run {label.upper()}: all nodes collected={summary['nodes_with_image_data'] == 3}")
        print(f"    Same image ID:      {summary['same_image_id_on_all_nodes']}")
        print(f"    Same image layers:  {summary['same_layers_on_all_nodes']}")
        print(f"    Same Raftly binary: {summary['same_raftly_binary_on_all_nodes']}")

    print("\nPer-node comparison")
    for node, data in report["nodes"].items():
        print(f"  {node}:")
        if "image_id_equal" in data:
            print(f"    Image ID equal:      {data['image_id_equal']}")
            print(f"    Layer DiffIDs equal: {data['layer_diffids_equal']}")
        value = data.get("raftly_binary_equal")
        print(f"    Raftly binary equal: {value if value is not None else 'not collected'}")
        if "apk_packages" in data:
            packages = data["apk_packages"]
            print(f"    Alpine packages:     {packages['count_a']} / {packages['count_b']}; equal={packages['equal']}")
            print(f"      Added: {len(packages['added_in_b'])}; removed: {len(packages['removed_in_b'])}")

    if "nix_closure" in report:
        closure = report["nix_closure"]
        print("\nNix closure")
        print(f"  Store paths:           {closure['store_path_count_a']} / {closure['store_path_count_b']}")
        print(f"  Same store paths:      {closure['same_store_paths']}")
        print(f"  Same names and hashes: {closure['same_store_objects_and_nar_hashes']}")
        print(f"  Added / removed:       {closure['added_store_path_count']} / {closure['removed_store_path_count']}")
        print(f"  Changed NAR hashes:    {closure['changed_nar_hash_count']}")

    print("\nNo overall reproducibility score is calculated.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_a", type=Path)
    parser.add_argument("run_b", type=Path)
    parser.add_argument("--json-out", type=Path, help="also write the full comparison as JSON")
    args = parser.parse_args()
    run_a, run_b = args.run_a.resolve(), args.run_b.resolve()
    report = compare(run_a, run_b)
    print_report(report)
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
