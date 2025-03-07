# Small program that runs the test cases

import std / [strutils, os, osproc, sequtils, strformat, unittest]
import basic/context
import testerutils

import unittests
import testtraverse
import testsemver

when not defined(quick):
  import testintegration

infoNow "tester", "All tests run successfully"
