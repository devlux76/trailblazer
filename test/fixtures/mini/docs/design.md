# Mini

## 1 Overview

Mini stores hikes and lists them. It is the fixture repository the core's
tests work on.

## 2 Storage

`Mini.Store.put/2` stores the hikes. The other `Mini.Store` in `test/support`
is there so that a qualified name can resolve to more than one definition.
