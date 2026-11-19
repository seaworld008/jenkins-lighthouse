#!/usr/bin/env python3
"""Tests for scan-job-commands.py (loaded by import, PATH-independent).

Run from the repository root:  python -m unittest discover -s tests -v
"""
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SCRIPT = os.path.join(REPO, "skills", "jenkins-lts-upgrade", "scripts", "scan-job-commands.py")
FIXTURES = os.path.join(HERE, "fixtures", "jobs")


def load_module():
    spec = importlib.util.spec_from_file_location("scan_job_commands", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["scan_job_commands"] = mod
    spec.loader.exec_module(mod)
    return mod


MOD = load_module()


def run_main(argv):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = MOD.main(argv)
    return rc, out.getvalue()


class ScanTests(unittest.TestCase):
    def test_summary_mode(self):
        rc, text = run_main([FIXTURES])
        self.assertEqual(rc, 0)
        self.assertIn("jobs: 2 (enabled 2, disabled 0)", text)
        self.assertIn("source /etc/profile: 2", text)
        self.assertIn("maven project type", text)
        self.assertIn("project", text)          # freestyle
        self.assertIn("flow-definition", text)  # pipeline

    def test_json_freestyle_commands_and_from_image(self):
        rc, text = run_main([FIXTURES, "--json"])
        self.assertEqual(rc, 0)
        jobs = {j["name"]: j for j in json.loads(text)}
        fs = jobs["demo-freestyle"]
        self.assertEqual(fs["type"], "project")
        self.assertFalse(fs["disabled"])
        self.assertEqual(fs["jdk"], "java")
        self.assertEqual(fs["label"], "build-agent")
        for cmd in ("mvn", "docker", "ssh", "rsync"):
            self.assertIn(cmd, fs["commands"], fs["commands"])
        self.assertTrue(fs["sources_profile"])
        self.assertIn("registry.example.com/library/base-nginx:1.25", fs["from_images"])
        self.assertIn("registry.example.com", fs["registries"])
        # SCM URL credentials are masked
        self.assertTrue(all("****" in u or "@" not in u for u in fs["scm_urls"]))

    def test_json_pipeline_script_content(self):
        rc, text = run_main([FIXTURES, "--json"])
        self.assertEqual(rc, 0)
        jobs = {j["name"]: j for j in json.loads(text)}
        pl = jobs["demo-pipeline"]
        self.assertEqual(pl["type"], "flow-definition")
        for cmd in ("mvn", "docker"):
            self.assertIn(cmd, pl["commands"], pl["commands"])
        self.assertTrue(pl["sources_profile"])
        self.assertIn("registry.example.com/library/base-openjdk8:latest", pl["from_images"])
        self.assertIn("registry.example.com", pl["registries"])

    def test_base_images_listing(self):
        rc, text = run_main([FIXTURES, "--base-images"])
        self.assertEqual(rc, 0)
        lines = dict(l.split("\t") for l in text.strip().splitlines())
        self.assertEqual(
            lines["registry.example.com/library/base-nginx:1.25"], "1")
        self.assertEqual(
            lines["registry.example.com/library/base-openjdk8:latest"], "1")

    def test_missing_directory_raises(self):
        with self.assertRaises(SystemExit):
            run_main([os.path.join(HERE, "does-not-exist")])

    def test_unparseable_config_is_reported_not_fatal(self):
        with tempfile.TemporaryDirectory() as d:
            jd = os.path.join(d, "broken-job")
            os.makedirs(jd)
            with open(os.path.join(jd, "config.xml"), "w", encoding="utf-8") as f:
                f.write("<project><not-closed>\n")
            rc, text = run_main([d, "--json"])
            self.assertEqual(rc, 0)
            jobs = json.loads(text)
            self.assertEqual(len(jobs), 1)
            self.assertEqual(jobs[0]["type"], "UNPARSEABLE")


if __name__ == "__main__":
    unittest.main()
