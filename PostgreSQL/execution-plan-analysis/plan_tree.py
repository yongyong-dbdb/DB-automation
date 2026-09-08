#!/usr/bin/env python3
"""PostgreSQL EXPLAIN (FORMAT JSON) structural renderer.

The renderer follows only PostgreSQL's JSON Plan/Plans hierarchy.  It emits a
compact plan-tree summary first and then the complete node properties returned
by PostgreSQL so existing detailed diagnostics remain available.
"""

import argparse
import json
import re
import sys
from pathlib import Path


RENDERER_VERSION = "1.2.0"


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


def compact_value(value):
    if value is None:
        return ""
    if isinstance(value, list):
        text = ", ".join(str(item) for item in value)
    elif isinstance(value, (dict, tuple)):
        text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    else:
        text = str(value)
    return " ".join(text.replace("\t", " ").replace("\r", " ").replace("\n", " ").split())


def node_display_name(node):
    name = str(node.get("Node Type", ""))
    index_name = node.get("Index Name")
    relation = node.get("Relation Name")
    schema = node.get("Schema")
    alias = node.get("Alias")

    if index_name:
        name += f" using {index_name}"

    if relation:
        relation_name = f"{schema}.{relation}" if schema else str(relation)
        name += f" on {relation_name}"
        if alias and alias != relation:
            name += f" {alias}"

    subplan_name = node.get("Subplan Name")
    if subplan_name:
        name += f" [{subplan_name}]"

    return name


def tree_rows(root):
    rows = []

    def walk(node, prefix="", connector=""):
        rows.append(
            {
                "Node-Type": f"{prefix}{connector}{node_display_name(node)}",
                "Sort-Key": compact_value(node.get("Sort Key")),
                "Index-Cond": compact_value(node.get("Index Cond")),
                "Recheck-Cond": compact_value(node.get("Recheck Cond")),
                "Hash-Cond": compact_value(node.get("Hash Cond")),
                "Merge-Cond": compact_value(node.get("Merge Cond")),
                "Join-Filter": compact_value(node.get("Join Filter")),
                "Filter": compact_value(node.get("Filter")),
            }
        )

        children = node.get("Plans", [])
        for idx, child in enumerate(children):
            last = idx == len(children) - 1
            child_connector = "└─ " if last else "├─ "
            child_prefix = prefix + ("   " if connector.startswith("└") else "│  " if connector else "")
            walk(child, child_prefix, child_connector)

    walk(root)
    return rows


def render_summary(root, out):
    validate_node(root)
    rows = tree_rows(root)
    columns = [
        "Node-Type",
        "Sort-Key",
        "Index-Cond",
        "Recheck-Cond",
        "Hash-Cond",
        "Merge-Cond",
        "Join-Filter",
        "Filter",
    ]

    widths = {}
    minimums = {
        "Node-Type": 30,
        "Sort-Key": 12,
        "Index-Cond": 14,
        "Recheck-Cond": 14,
        "Hash-Cond": 12,
        "Merge-Cond": 12,
        "Join-Filter": 12,
        "Filter": 12,
    }
    maximums = {
        "Node-Type": 56,
        "Sort-Key": 32,
        "Index-Cond": 48,
        "Recheck-Cond": 40,
        "Hash-Cond": 40,
        "Merge-Cond": 40,
        "Join-Filter": 40,
        "Filter": 48,
    }

    for column in columns:
        observed = max([len(column)] + [len(row[column]) for row in rows])
        widths[column] = min(max(observed, minimums[column]), maximums[column])

    def clip(text, width):
        if len(text) <= width:
            return text
        if width <= 3:
            return text[:width]
        return text[: width - 3] + "..."

    def line(values):
        return " | ".join(clip(values[column], widths[column]).ljust(widths[column]) for column in columns)

    out.write("Plan Tree Summary\n")
    out.write(line({column: column for column in columns}) + "\n")
    out.write("-+-".join("-" * widths[column] for column in columns) + "\n")
    for row in rows:
        out.write(line(row) + "\n")


def render_details(document, root, out):
    validate_node(root)

    def walk(node, prefix="", connector=""):
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
            walk(child, child_prefix, child_connector)

    walk(root)

    top_level = [(k, v) for k, v in document.items() if k != "Plan"]
    if top_level:
        out.write("\nEXPLAIN Document Properties\n")
        for key, value in top_level:
            out.write(f"· {key}: {json_value(value)}\n")


def render_tree(document, root, out):
    render_summary(root, out)
    out.write("\nNode Details\n")
    out.write("------------\n")
    render_details(document, root, out)


def quote_ident(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def relation_reference(schema: str, relation: str) -> str:
    """Return a regclass-safe relation reference.

    Existing diagnostics historically consume ordinary schema.table strings,
    so simple lower-case PostgreSQL identifiers remain unquoted. Identifiers
    requiring quoting are quoted without changing their value.
    """
    simple_ident = re.compile(r"^[a-z_][a-z0-9_$]*$")
    schema_ref = schema if simple_ident.match(schema) else quote_ident(schema)
    relation_ref = relation if simple_ident.match(relation) else quote_ident(relation)
    return f"{schema_ref}.{relation_ref}"


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
            relations.add(relation_reference(schema, relation))

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
        {"Plan": {"Node Type": "Seq Scan", "Relation Name": "t", "Schema": "public", "Plan Rows": 10}},
        {
            "Plan": {
                "Node Type": "Nested Loop",
                "Plans": [
                    {"Node Type": "Seq Scan", "Parent Relationship": "Outer"},
                    {"Node Type": "Index Scan", "Parent Relationship": "Inner", "Index Name": "t_pkey"},
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
        {"Plan": {"Node Type": "ModifyTable", "Operation": "Update", "Plans": [{"Node Type": "Seq Scan"}]}},
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
            raise PlanFormatError(f"self-test fixture {idx}: expected {expected} nodes, got {actual}")

    summary_fixture = {
        "Node Type": "Hash Join",
        "Hash Cond": "(a.id = b.id)",
        "Plans": [
            {"Node Type": "Seq Scan", "Schema": "public", "Relation Name": "a", "Alias": "a", "Filter": "(a.flag = true)"},
            {"Node Type": "Hash", "Plans": [{"Node Type": "Index Scan", "Index Name": "b_pkey", "Schema": "public", "Relation Name": "b", "Alias": "b", "Index Cond": "(b.id > 0)"}]},
        ],
    }
    rows = tree_rows(summary_fixture)
    if len(rows) != 4:
        raise PlanFormatError("self-test: plan summary row count failed")
    if rows[0]["Hash-Cond"] != "(a.id = b.id)":
        raise PlanFormatError("self-test: Hash Cond extraction failed")
    if "using b_pkey on public.b" not in rows[3]["Node-Type"]:
        raise PlanFormatError("self-test: index/relation display failed")
    if rows[3]["Index-Cond"] != "(b.id > 0)":
        raise PlanFormatError("self-test: Index Cond extraction failed")

    if relation_reference("public", "orders") != "public.orders":
        raise PlanFormatError("self-test: ordinary relation formatting failed")
    if relation_reference("Mixed Schema", "Order.Table") != '"Mixed Schema"."Order.Table"':
        raise PlanFormatError("self-test: quoted relation formatting failed")

    print(f"plan_tree.py v{RENDERER_VERSION} self-test passed: {len(fixtures)} structural fixtures")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    p_tree = sub.add_parser("tree")
    p_tree.add_argument("plan_json")

    p_summary = sub.add_parser("summary")
    p_summary.add_argument("plan_json")

    p_details = sub.add_parser("details")
    p_details.add_argument("plan_json")

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
        elif args.command == "summary":
            render_summary(root, sys.stdout)
        elif args.command == "details":
            render_details(document, root, sys.stdout)
        elif args.command == "metadata":
            write_metadata(root, args.relations_file, args.dml_file)
        return 0
    except PlanFormatError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
