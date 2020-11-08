
import os
import strutils
import lists
import json
import terminal
import tables
import options
import sets

import cirru_parser
import cirru_edn
import ternary_tree

import calcit_runner/types
import calcit_runner/core_syntax
import calcit_runner/core_func
import calcit_runner/core_abstract
import calcit_runner/errors
import calcit_runner/loader
import calcit_runner/stack
import calcit_runner/gen_data
import calcit_runner/evaluate
import calcit_runner/eval_util
import calcit_runner/to_json

# slots for dynamic registering GUI functions
var onLoadPluginProcs: Table[string, FnInData]

export CirruData, CirruDataKind, `==`, crData

var codeConfigs = CodeConfigs(initFn: "app.main/main!", reloadFn: "app.main/reload!")

proc registerCoreProc*(procName: string, f: FnInData) =
  onLoadPluginProcs[procName] = f

proc runCode(ns: string, def: string, data: CirruData, dropArg: bool = false): CirruData =
  let scope = CirruDataScope()

  try:
    preprocessSymbolByPath(ns, def)
    let entry = getEvaluatedByPath(ns, def, scope)

    if entry.kind != crDataFn:
      raise newException(ValueError, "expects a function at " & ns & "/" & def)

    let mainCode = programCode[ns].defs[def]
    defStack = initDoublyLinkedList[StackInfo]()
    pushDefStack StackInfo(ns: ns, def: def, code: mainCode)

    let args = if dropArg: @[] else: @[data]
    let ret = evaluteFnData(entry, args, interpret, ns)
    popDefStack()

    return ret

  except CirruEvalError as e:
    echo ""
    coloredEcho fgRed, e.msg, " ", $e.code
    showStack()
    echo ""
    raise e

  except CirruCoreError as e:
    echo ""
    coloredEcho fgRed, e.msg, " ", $e.data
    showStack()
    echo ""
    raise e

  except Defect as e:
    coloredEcho fgRed, "Failed to run command"
    echo e.msg

proc runProgram*(snapshotFile: string, initFn: Option[string] = none(string)): CirruData =
  let snapshotInfo = loadSnapshot(snapshotFile)
  programCode = snapshotInfo.files
  codeConfigs = snapshotInfo.configs

  programData.clear

  programCode[coreNs] = FileSource()
  programData[coreNs] = ProgramFile()

  loadCoreDefs(programData, interpret)
  loadCoreSyntax(programData, interpret)

  loadCoreFuncs(programCode)

  # register temp functions
  for procName, tempProc in onLoadPluginProcs:
    programData[coreNs].defs[procName] = CirruData(kind: crDataProc, procVal: tempProc)

  let pieces = if initFn.isSome:
    initFn.get.split("/")
  else:
   codeConfigs.initFn.split('/')

  if pieces.len != 2:
    echo "Unknown initFn", pieces
    raise newException(ValueError, "Unknown initFn")

  runCode(pieces[0], pieces[1], CirruData(kind: crDataNil), true)

proc runEventListener*(event: JsonNode) =

  discard runCode("app.main", "on-window-event", event.toCirruData)

proc reloadProgram(snapshotFile: string): void =
  let previousCoreSource = programCode[coreNs]
  programCode = loadSnapshot(snapshotFile).files
  clearProgramDefs(programData)
  programCode[coreNs] = previousCoreSource
  let pieces = codeConfigs.reloadFn.split('/')

  if pieces.len != 2:
    echo "Unknown initFn", pieces
    raise newException(ValueError, "Unknown initFn")

  discard runCode(pieces[0], pieces[1], CirruData(kind: crDataNil), true)

let handleFileChange* = proc (snapshotFile: string, incrementFile: string): void =
  sleep 150
  coloredEcho fgYellow, "\n-------- file change --------\n"
  loadChanges(incrementFile, programCode)
  try:
    reloadProgram(snapshotFile)

  except ValueError as e:
    coloredEcho fgRed, "Failed to rerun program: ", e.msg

  except CirruParseError as e:
    coloredEcho fgRed, "\nError: failed to parse"
    echo e.msg

  except CirruCommandError as e:
    coloredEcho fgRed, "Failed to run command"
    echo e.msg

