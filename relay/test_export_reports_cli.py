import contextlib
import io
import sys
import unittest
from pathlib import Path
from unittest import mock

from relay import export_reports


class ExportReportsCliTests(unittest.TestCase):
    def test_since_unix_is_forwarded_to_archive_builder(self):
        argv = ["export_reports.py", "--storage-dir", "/tmp/inbox", "--identity-file", "/tmp/key", "--output", "/tmp/out.zip", "--since-unix", "1700000000"]
        output = io.StringIO()
        with mock.patch.object(sys, "argv", argv), mock.patch.object(export_reports.os, "geteuid", return_value=0, create=True), mock.patch.object(export_reports, "build_bulk_archive", return_value=3) as builder, contextlib.redirect_stdout(output):
            self.assertEqual(export_reports.main(), 0)
        self.assertEqual(builder.call_args.args, (Path("/tmp/inbox"), Path("/tmp/key"), Path("/tmp/out.zip")))
        self.assertEqual(builder.call_args.kwargs, {"since_unix": 1700000000})
        self.assertEqual(output.getvalue(), "exported 3 report(s)\n")


if __name__ == "__main__":
    unittest.main()
