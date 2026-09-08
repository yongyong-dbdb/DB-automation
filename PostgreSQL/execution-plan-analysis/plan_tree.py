#!/usr/bin/env python3
"""PostgreSQL EXPLAIN (FORMAT JSON) structural renderer.

This helper intentionally does not infer plan semantics.  It follows only the
JSON structure returned by PostgreSQL: the top-level Plan object and each
node's Plans array.  Node properties are emitted with their original JSON key
names and values.
"""

import argparse
import json
import sys
from pathlib import Path


class PlanFormatError(RuntimeError):
    pass


def load_document(path: str):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        raise PlanFormatError(f"cannot read PostgreSQL JSON plan: {exc}") from exc

    if not isinstance(data, list) or not data:
        raise PlanFormatError("top-level EXPLAIN JSON value must be a non-empty array")
    if not isinstance(data[0], dict):
        raise PlanFormatError("first EXPLAIN JSON array element must be an object")

    document = data[0]
    plan = document.get("Plan")
    if not isinstance(plan, dict):
        raise PlanFormatError("EXPLAIN JSON document does not contain an object-valued Plan field")

    return data, document, plan


def json_value(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def validate_node(node, path="Plan"):
    if not isinstance(node, dict):
        raise PlanFormatError(f"{path} must be an object")

    node_type = node.get("Node Type")
    if not isinstance(node_type, str) or not node_type:
        raise PlanFormatError(f"{path} does not contain a non-empty Node Type string")

    if "Plans" in node:
        plans = node["Plans"]
        if not isinstance(plans, list):
            raise PlanFormatError(f"{path}.Plans must be an array")
        for idx, child in enumerate(plans):
            validate_node(child, f"{path}.Plans[{idx}]")


def render_tree(document, root, out):
    validate_node(root)

    def walk(node, prefix="", connector="", path="Plan"):
        out.write(f"{prefix}{connector}Node Type: {node['Node Type']}\n")

        detail_prefix = prefix + ("   " if connector == "" or connector.startswith("└") else "│  ")
        for key, value in node.items():
            if key in ("Node Type", "Plans"):
                continue
            out.write(f"{detail_prefix}· {key}: {json_value(value)}\n")

        children = node.get("Plans", [])
        for idx, child in enumerate(children):
            last = idx == len(children) - 1
            child_connector = "└─ " if last else "├─ "
            if connector == "":
                child_prefix = ""
            else:
                child_prefix = prefix + ("   " if connector.startswith("└") else "│  ")
            walk(child, child_prefix, child_connector, f"{path}.Plans[{idx}]")

    walk(root)

    top_level = [(k, v) for k, v in document.items() if k != "Plan"]
    if top_level:
        out.write("\nEXPLAIN Document Properties\n")
        for key, value in top_level:
            out.write(f"· {key}: {json_value(value)}\n")


def quote_ident(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def walk_nodes(root):
    stack = [root]
    while stack:
        node = stack.pop()
        yield node
        children = node.get("Plans", [])
        for child in reversed(children):
            stack.append(child)


def write_metadata(root, relations_path: str, dml_path: str):
    validate_node(root)

    relations = set()
    operations = []
    for node in walk_nodes(root):
        schema = node.get("Schema")
        relation = node.get("Relation Name")
        if isinstance(schema, str) and isinstance(relation, str):
            relations.add(f"{quote_ident(schema)}.{quote_ident(relation)}")

        operation = node.get("Operation")
        if operation in {"Insert", "Update", "Delete", "Merge"} and operation not in operations:
            operations.append(operation)

    try:
        Path(relations_path).write_text(
            "".join(f"{rel}\n" for rel in sorted(relations)), encoding="utf-8"
        )
        Path(dml_path).write_text(
            "".join(f"{op}\n" for op in operations), encoding="utf-8"
        )
    except OSError as exc:
        raise PlanFormatError(f"cannot write metadata output: {exc}") from exc


def count_nodes(root):
    return sum(1 for _ in walk_nodes(root))


def self_test():
    fixtures = [
        {
            "Plan": {
                "Node Type": "Seq Scan",
                "Relation Name": "t",
                "Schema": "public",
                "Plan Rows": 10,
            }
        },
        {
            "Plan": {
                "Node Type": "Nested Loop",
                "Plans": [
                    {"Node Type": "Seq Scan", "Parent Relationship": "Outer"},
                    {
                        "Node Type": "Index Scan",
                        "Parent Relationship": "Inner",
                        "Index Name": "t_pkey",
                    },
                ],
            }
        },
        {
            "Plan": {
                "Node Type": "Hash Join",
                "Plans": [
                    {"Node Type": "Seq Scan"},
                    {"Node Type": "Hash", "Plans": [{"Node Type": "Seq Scan"}]},
                ],
            }
        },
        {
            "Plan": {
                "Node Type": "Bitmap Heap Scan",
                "Plans": [
                    {
                        "Node Type": "BitmapAnd",
                        "Plans": [
                            {"Node Type": "Bitmap Index Scan"},
                            {"Node Type": "Bitmap Index Scan"},
                        ],
                    }
                ],
            }
        },
        {
            "Plan": {
                "Node Type": "Append",
                "Plans": [
                    {"Node Type": "Seq Scan", "Relation Name": "p1", "Schema": "public"},
                    {"Node Type": "Index Scan", "Relation Name": "p2", "Schema": "public"},
                ],
            }
        },
        {
            "Plan": {
                "Node Type": "ModifyTable",
                "Operation": "Update",
                "Plans": [{"Node Type": "Seq Scan"}],
            }
        },
        {
            "Plan": {
                "Node Type": "Result",
                "Plans": [
                    {
                        "Node Type": "Aggregate",
                        "Parent Relationship": "SubPlan",
                        "Subplan Name": "SubPlan 1",
                        "Plans": [{"Node Type": "Index Scan"}],
                    }
                ],
            }
        },
        {
            "Plan": {
                "Node Type": "CTE Scan",
                "CTE Name": "q",
                "Plans": [
                    {
                        "Node Type": "Aggregate",
                        "Parent Relationship": "InitPlan",
                        "Subplan Name": "CTE q",
                    }
                ],
            }
        },
        {
            "Plan": {
                "Node Type": "Gather",
                "Workers Planned": 2,
                "Workers Launched": 2,
                "Workers": [{"Worker Number": 0}, {"Worker Number": 1}],
                "Plans": [{"Node Type": "Parallel Seq Scan"}],
            }
        },
        {
            "Plan": {
                "Node Type": "Memoize",
                "Cache Key": "x.id",
                "Plans": [{"Node Type": "Index Only Scan", "Actual Loops": 0}],
            }
        },
        {
            "Plan": {
                "Node Type": "Future Node Name",
                "Future Property": {"nested": [1, 2, 3]},
                "Plans": [{"Node Type": "Another Future Node"}],
            }
        },
    ]

    expected_counts = [1, 3, 4, 4, 3, 2, 3, 2, 2, 2, 2]
    for idx, (doc, expected) in enumerate(zip(fixtures, expected_counts), start=1):
        root = doc["Plan"]
        validate_node(root)
        actual = count_nodes(root)
        if actual != expected:
            raise PlanFormatError(
                f"self-test fixture {idx}: expected {expected} nodes, got {actual}"
            )

    print(f"plan_tree.py self-test passed: {len(fixtures)} fixtures")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    p_tree = sub.add_parser("tree")
    p_tree.add_argument("plan_json")

    p_meta = sub.add_parser("metadata")
    p_meta.add_argument("plan_json")
    p_meta.add_argument("relations_file")
    p_meta.add_argument("dml_file")

    sub.add_parser("self-test")

    args = parser.parse_args()

    try:
        if args.command == "self-test":
            self_test()
            return 0

        _, document, root = load_document(args.plan_json)
        if args.command == "tree":
            render_tree(document, root, sys.stdout)
        elif args.command == "metadata":
            write_metadata(root, args.relations_file, args.dml_file)
        return 0
    except PlanFormatError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
