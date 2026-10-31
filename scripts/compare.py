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
    return path.read_text(encoding="utf-8").split()[0]


def image_details(run: Path, node: str) -> dict[str, Any] | None:
    path = run / "nodes" / node / "image-inspect.json"
    if not path.is_file():
        return None
    value = load_json(path)
    return value[0] if isinstance(value, list) else value


def sbom_packages(path: Path) -> set[tuple[str, str, str]] | None:
    if not path.is_file():
        return None
    data = load_json(path)
    return {
        (item.get("name", ""), item.get("version", ""), item.get("purl", ""))
        for item in data.get("components", [])
    }


def apk_packages(path: Path) -> set[str] | None:
    if not path.is_file():
        return None
    return {line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()}


def nix_inventory(path: Path) -> dict[str, str | None] | None:
    if not path.is_file():
        return None
    return {
        item.get("store_path", ""): item.get("nar_hash")
        for item in load_json(path)
    }


def metadata(run: Path) -> dict[str, Any]:
    path = run / "metadata.json"
    if not path.is_file():
        raise SystemExit(f"Missing {path}")
    return load_json(path)


def result_status(run: Path) -> str:
    path = run / "result.json"
    if not path.is_file():
        return "unknown"
    return load_json(path).get("status", "unknown")


def compare(run_a: Path, run_b: Path) -> dict[str, Any]:
    ma, mb = metadata(run_a), metadata(run_b)
    same_method = ma.get("method") == mb.get("method")
    input_hashes_a = (run_a / "inputs" / "files.sha256").read_text(encoding="utf-8") if (run_a / "inputs" / "files.sha256").is_file() else None
    input_hashes_b = (run_b / "inputs" / "files.sha256").read_text(encoding="utf-8") if (run_b / "inputs" / "files.sha256").is_file() else None
    base_ids_a = (run_a / "inputs" / "docker-base-image-identities.txt").read_text(encoding="utf-8") if (run_a / "inputs" / "docker-base-image-identities.txt").is_file() else None
    base_ids_b = (run_b / "inputs" / "docker-base-image-identities.txt").read_text(encoding="utf-8") if (run_b / "inputs" / "docker-base-image-identities.txt").is_file() else None
    report: dict[str, Any] = {
        "run_a": str(run_a),
        "run_b": str(run_b),
        "method_a": ma.get("method"),
        "method_b": mb.get("method"),
        "result_a": result_status(run_a),
        "result_b": result_status(run_b),
        "build_duration_seconds_a": int((run_a / "build-duration-seconds.txt").read_text().strip()) if (run_a / "build-duration-seconds.txt").is_file() else None,
        "build_duration_seconds_b": int((run_b / "build-duration-seconds.txt").read_text().strip()) if (run_b / "build-duration-seconds.txt").is_file() else None,
        "same_method": same_method,
        "inputs": {
            "build_definition_hashes_equal": input_hashes_a == input_hashes_b if input_hashes_a is not None and input_hashes_b is not None else None,
            "docker_base_image_identities_equal": base_ids_a == base_ids_b if base_ids_a is not None and base_ids_b is not None else None,
            "tool_versions_a": ma.get("tools", {}),
            "tool_versions_b": mb.get("tools", {}),
        },
        "source": {
            "raftly_commit_a": ma.get("raftly_submodule_commit"),
            "raftly_commit_b": mb.get("raftly_submodule_commit"),
            "same_raftly_submodule_commit": ma.get("raftly_submodule_commit") == mb.get("raftly_submodule_commit"),
            "nix_source_matches_submodule_a": ma.get("raftly_source_revision_matches"),
            "nix_source_matches_submodule_b": mb.get("raftly_source_revision_matches"),
        },
        "nodes": {},
    }

    for node in NODES:
        a, b = image_details(run_a, node), image_details(run_b, node)
        node_result: dict[str, Any] = {}
        if a is not None and b is not None:
            node_result["architecture_a"] = a.get("Architecture")
            node_result["architecture_b"] = b.get("Architecture")
            if same_method:
                node_result["image_id_a"] = a.get("Id")
                node_result["image_id_b"] = b.get("Id")
                node_result["image_id_equal"] = a.get("Id") == b.get("Id")
                layers_a = a.get("RootFS", {}).get("Layers", [])
                layers_b = b.get("RootFS", {}).get("Layers", [])
                node_result["layer_diffids_equal"] = layers_a == layers_b
                node_result["layer_count_a"] = len(layers_a)
                node_result["layer_count_b"] = len(layers_b)

        bin_a = read_hash(run_a / "nodes" / node / "raftly-server.sha256")
        bin_b = read_hash(run_b / "nodes" / node / "raftly-server.sha256")
        node_result["raftly_binary_sha256_a"] = bin_a
        node_result["raftly_binary_sha256_b"] = bin_b
        node_result["raftly_binary_equal"] = bin_a == bin_b if bin_a and bin_b else None

        apk_a = apk_packages(run_a / "nodes" / node / "apk-packages.txt")
        apk_b = apk_packages(run_b / "nodes" / node / "apk-packages.txt")
        if same_method and apk_a is not None and apk_b is not None:
            node_result["apk_packages"] = {
                "count_a": len(apk_a),
                "count_b": len(apk_b),
                "added_in_b": sorted(apk_b - apk_a),
                "removed_in_b": sorted(apk_a - apk_b),
                "equal": apk_a == apk_b,
            }

        sbom_a = sbom_packages(run_a / "nodes" / node / "sbom.cdx.json")
        sbom_b = sbom_packages(run_b / "nodes" / node / "sbom.cdx.json")
        if same_method and sbom_a is not None and sbom_b is not None:
            node_result["sbom"] = {
                "count_a": len(sbom_a),
                "count_b": len(sbom_b),
                "added_in_b": sorted(sbom_b - sbom_a),
                "removed_in_b": sorted(sbom_a - sbom_b),
                "equal": sbom_a == sbom_b,
            }
        report["nodes"][node] = node_result

    nix_a = nix_inventory(run_a / "nix-store-inventory.json")
    nix_b = nix_inventory(run_b / "nix-store-inventory.json")
    if same_method and nix_a is not None and nix_b is not None:
        common = set(nix_a) & set(nix_b)
        def object_inventory(run: Path) -> Counter[tuple[str, str | None]]:
            rows = load_json(run / "nix-store-inventory.json")
            return Counter((item.get("store_name", ""), item.get("nar_hash")) for item in rows)
        objects_a, objects_b = object_inventory(run_a), object_inventory(run_b)
        report["nix_closure"] = {
            "path_count_a": len(nix_a),
            "path_count_b": len(nix_b),
            "same_store_paths": set(nix_a) == set(nix_b),
            "changed_nar_hashes": sorted(path for path in common if nix_a[path] != nix_b[path]),
            "added_in_b": sorted(set(nix_b) - set(nix_a)),
            "removed_in_b": sorted(set(nix_a) - set(nix_b)),
            "same_store_objects_and_nar_hashes": objects_a == objects_b,
            "all_paths_and_hashes_equal": nix_a == nix_b,
        }

    return report


def print_report(report: dict[str, Any]) -> None:
    print("Raftly environment comparison")
    print(f"A: {report['run_a']} ({report['method_a']}, {report['result_a']})")
    print(f"B: {report['run_b']} ({report['method_b']}, {report['result_b']})")
    print(f"Build duration: A={report['build_duration_seconds_a']}s B={report['build_duration_seconds_b']}s")
    print()

    source = report["source"]
    inputs = report["inputs"]
    print("Build inputs")
    print(f"  Build definition hashes equal: {inputs['build_definition_hashes_equal']}")
    if inputs["docker_base_image_identities_equal"] is not None:
        print(f"  Docker base image identities equal: {inputs['docker_base_image_identities_equal']}")
    print(f"  Tool versions equal: {inputs['tool_versions_a'] == inputs['tool_versions_b']}")

    print("\nArtifact source")
    print(f"  Same Raftly submodule commit: {source['same_raftly_submodule_commit']}")
    print(f"  Nix source matches submodule:  A={source['nix_source_matches_submodule_a']} B={source['nix_source_matches_submodule_b']}")

    if not report["same_method"]:
        print("\nDifferent build methods: image IDs and Nix NAR hashes identify different objects.")
        print("Use the application binary hash as the direct cross-method byte comparison.")

    print("\nNode images and application binaries")
    for node, data in report["nodes"].items():
        print(f"  {node}:")
        if "image_id_equal" in data:
            print(f"    image ID equal:       {data['image_id_equal']}")
            print(f"    layer DiffIDs equal:  {data['layer_diffids_equal']}")
        value = data.get("raftly_binary_equal")
        print(f"    Raftly binary equal:  {value if value is not None else 'not collected'}")
        if "apk_packages" in data:
            package = data["apk_packages"]
            print(f"    Alpine packages:      {package['count_a']} / {package['count_b']}; equal={package['equal']}")
            print(f"      added: {len(package['added_in_b'])}; removed: {len(package['removed_in_b'])}")
        if "sbom" in data:
            sbom = data["sbom"]
            print(f"    SBOM components:      {sbom['count_a']} / {sbom['count_b']}; equal={sbom['equal']}")

    if "nix_closure" in report:
        closure = report["nix_closure"]
        print("\nNix closure")
        print(f"  Store paths:            {closure['path_count_a']} / {closure['path_count_b']}")
        print(f"  Paths and NAR hashes equal: {closure['all_paths_and_hashes_equal']}")
        print(f"  Store objects and NAR hashes equal: {closure['same_store_objects_and_nar_hashes']}")
        print(f"  Added/removed paths:    {len(closure['added_in_b'])} / {len(closure['removed_in_b'])}")
        print(f"  Changed NAR hashes:     {len(closure['changed_nar_hashes'])}")

    print("\nNo single reproducibility score is calculated.")


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
