# SPDX-License-Identifier: GPL-3.0-or-later

"""vostok tool geometry: anchoring and per-line alignment of statement records."""

import unittest

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


if __name__ == "__main__":
    unittest.main()
