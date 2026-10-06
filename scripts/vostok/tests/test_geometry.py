# SPDX-License-Identifier: GPL-3.0-or-later

"""vostok tool geometry: anchoring and per-line alignment of statement records."""

import tempfile
import unittest
from pathlib import Path

from vostok.tool import geometry


def function(file, *records):
    return {"file": file, "statements": [
        {"off": off, "size": size, "line": line, **({"file": f} if f else {})}
        for off, size, line, f in records]}


class GeometryTests(unittest.TestCase):
    def test_anchor_is_first_record_by_offset_and_other_files_split_out(self):
        anchor, lines, other = geometry._relative(function(
            "a.cpp", (0x10, 5, 12, None), (0, 22, 10, None), (0x20, 3, 99, "b.h")))
        self.assertEqual(anchor, 10)
        self.assertEqual(lines, {0: [22], 2: [5]})
        self.assertEqual(other, {"b.h": 1})

    def test_records_on_one_line_keep_offset_order(self):
        _, lines, _ = geometry._relative(function(
            "a.cpp", (0, 1, 5, None), (8, 2, 7, None), (4, 3, 7, None)))
        self.assertEqual(lines[2], [3, 2])

    def test_matching_geometry_only_marks_byte_differences(self):
        rows = geometry.geometry_rows({0: [22], 6: [5], 18: [1, 85]},
                                      {0: [14], 6: [5], 18: [1, 88]})
        self.assertFalse([r for r in rows if r[3] in geometry.DIVERGENT])
        self.assertEqual([r[0] for r in rows if r[3] == "bytes"], [0, 18])
        self.assertEqual([r[0] for r in rows], list(range(0, 19)))

    def test_one_sided_and_count_mismatches_are_flagged(self):
        rows = {r[0]: r[3] for r in geometry.geometry_rows(
            {0: [1], 3: [5], 5: [1, 1]}, {0: [1], 2: [5], 5: [2]})}
        self.assertEqual(rows[2], "ours only")
        self.assertEqual(rows[3], "retail only")
        self.assertEqual(rows[5], "records")
        self.assertEqual(rows[1], "")

    def test_empty_sides(self):
        self.assertEqual(geometry.geometry_rows({}, {}), [])


class IgnoreTests(unittest.TestCase):
    def table(self, *rows):
        handle = tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False)
        handle.write("# function\tat\tlines\treason\n" + "".join(r + "\n" for r in rows))
        handle.close()
        self.addCleanup(Path(handle.name).unlink)
        return Path(handle.name)

    def test_rows_for_this_function_only_sorted(self):
        path = self.table("?f@@\t9\t2\t#ifdef'd log", "?g@@\t1\t1\tother",
                          "?f@@\t3\t-1\tcomment we keep")
        self.assertEqual(geometry.load_ignores(path, "?f@@"),
                         [(3, -1, "comment we keep"), (9, 2, "#ifdef'd log")])

    def test_missing_table_means_no_gaps(self):
        self.assertEqual(geometry.load_ignores(Path("/nonexistent.tsv"), "?f@@"), [])

    def test_malformed_rows_name_the_file_line(self):
        for row in ("?f@@\t3\t1", "?f@@\tx\t1\treason", "?f@@\t3\t0\treason",
                    "?f@@\t3\t1\t "):
            with self.assertRaises(SystemExit) as caught:
                geometry.load_ignores(self.table(row), "?f@@")
            self.assertIn(".tsv:2:", str(caught.exception))

    def test_positive_gap_shifts_later_lines_and_labels_the_gap(self):
        framed, ours_at, reasons, skipped = geometry.to_frame(
            {0: [5], 4: [7]}, [(2, 3, "debug block")], range(0, 5))
        self.assertEqual(framed, {0: [5], 7: [7]})
        self.assertEqual(ours_at[7], 4)
        self.assertEqual(reasons, {2: "debug block", 3: "debug block", 4: "debug block"})
        self.assertEqual(skipped, [])

    def test_negative_gap_skips_our_extra_lines(self):
        framed, ours_at, _, skipped = geometry.to_frame(
            {0: [5], 6: [7]}, [(2, -2, "our comment")], range(0, 7))
        self.assertEqual(framed, {0: [5], 4: [7]})
        self.assertNotIn(2, ours_at.values())
        self.assertEqual(skipped, [])

    def test_records_inside_a_negative_gap_are_reported(self):
        _, _, _, skipped = geometry.to_frame({0: [5], 2: [3]}, [(2, -1, "x")], range(0, 3))
        self.assertEqual(skipped, [(2, "x", [3])])


if __name__ == "__main__":
    unittest.main()
