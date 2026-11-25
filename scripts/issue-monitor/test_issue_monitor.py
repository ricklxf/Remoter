#!/usr/bin/env python3
"""Unit tests for issue_monitor.py."""

from __future__ import annotations

import unittest

import issue_monitor as im


class IssueMonitorTests(unittest.TestCase):
    def test_filter_new_issues_skips_processed_and_ignored_labels(self) -> None:
        issues = [
            {
                "number": 5,
                "title": "Already handled",
                "labels": [{"name": "bug"}],
            },
            {
                "number": 8,
                "title": "Ignored wontfix",
                "labels": [{"name": "WontFix"}],
            },
            {
                "number": 10,
                "title": "Real new bug",
                "labels": [{"name": "bug"}],
            },
            {
                "number": 7,
                "title": "Earlier new feature",
                "labels": [{"name": "enhancement"}],
            },
        ]
        processed = {"5": {"status": "bug_fixed_pr"}}
        result = im.filter_new_issues(
            issues=issues,
            processed=processed,
            ignore_labels=["wontfix", "duplicate"],
        )
        self.assertEqual([item["number"] for item in result], [7, 10])

    def test_build_telegram_html_escapes_special_chars(self) -> None:
        msg = im.build_telegram_html(
            notify_type="feature",
            repo="ricklxf/Remoter",
            issue_number=42,
            title="Support <AV1> & H.265",
            url="https://github.com/ricklxf/Remoter/issues/42",
            summary="用户希望增加 <AV1> 编码选项 & 自动协商。",
        )
        self.assertIn("[新需求 / 功能建议]", msg)
        self.assertIn("Support &lt;AV1&gt; &amp; H.265", msg)
        self.assertIn("&lt;AV1&gt; 编码选项 &amp; 自动协商", msg)
        self.assertIn('href="https://github.com/ricklxf/Remoter/issues/42"', msg)

    def test_build_telegram_html_includes_pr_url(self) -> None:
        msg = im.build_telegram_html(
            notify_type="bug-fixed",
            repo="ricklxf/Remoter",
            issue_number=12,
            title="Crash on reconnect",
            url="https://github.com/ricklxf/Remoter/issues/12",
            pr_url="https://github.com/ricklxf/Remoter/pull/13",
            summary="修复了断线重连时的空指针崩溃。",
        )
        self.assertIn("[Bug 已自动修复并提 PR]", msg)
        self.assertIn("https://github.com/ricklxf/Remoter/pull/13", msg)


if __name__ == "__main__":
    unittest.main()
