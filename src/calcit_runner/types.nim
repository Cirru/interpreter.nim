
import tables
import options
import sets
import hashes
import sequtils
import strutils
import math
import strformat

import ternary_tree

type
  RefKeyword* = ref string

var keywordRegistry: Table[string, RefKeyword]

proc loadKeyword*(content: string): RefKeyword =
  if not keywordRegistry.contains(content):
    var k = new RefKeyword
    k[] = content
    keywordRegistry[content] = k

  return keywordRegistry[content]

type CirruCommandError* = ValueError

type ImportKind* = enum
  importNs, importDef
type ImportInfo* = object
  ns*: string
  case kind*: ImportKind
  of importNs:
    discard
  of importDef:
    def*: string

type

  CirruDataScope* = TernaryTreeMap[string, CirruData]

  CirruDataKind* = enum
    crDataNil,
    crDataBool,
    crDataNumber,
    crDataString,
    crDataKeyword,
    crDataList,
    crDataSet,
    crDataMap,
    crDataProc,
    crDataFn,
    crDataMacro,
    crDataSymbol,
    crDataSyntax,
    crDataRecur,
    crDataAtom,

  FnInterpret* = proc(expr: CirruData, scope: CirruDataScope, ns: string): CirruData

  FnInData* = proc(exprList: seq[CirruData], interpret: FnInterpret, scope: CirruDataScope, ns: string): CirruData

  ResolvedPath* = tuple[ns: string, def: string]

  CirruData* = object
    case kind*: CirruDataKind
    of crDataNil: discard
    of crDataBool: boolVal*: bool
    of crDataNumber: numberVal*: float
    of crDataString: stringVal*: string
    of crDataKeyword: keywordVal*: RefKeyword
    of crDataProc:
      procVal*: FnInData
    of crDataFn:
      fnName*: string
      fnScope*: CirruDataScope
      fnArgs*: TernaryTreeList[CirruData]
      fnCode*: seq[CirruData]
      fnNs*: string
    of crDataMacro:
      macroName*: string
      macroArgs*: TernaryTreeList[CirruData]
      macroCode*: seq[CirruData]
      macroNs*: string
    of crDataSyntax:
      syntaxVal*: FnInData
    of crDataList: listVal*: TernaryTreeList[CirruData]
    of crDataSet: setVal*: HashSet[CirruData]
    of crDataMap: mapVal*: TernaryTreeMap[CirruData, CirruData]
    of crDataSymbol:
      symbolVal*: string
      ns*: string
      resolved*: Option[ResolvedPath]
      # TODO looking for simpler solution
      dynamic*: bool
    of crDataRecur:
      recurArgs*: seq[CirruData]
    of crDataAtom:
      atomNs*: string
      atomDef*: string

  RefCirruData* = ref CirruData

  EdnEmptyError* = object of ValueError
  EdnInvalidError* = object of ValueError

type ProgramFile* = object
  ns*: Option[Table[string, ImportInfo]]
  defs*: Table[string, CirruData]
  states*: Table[string, CirruData]

type CodeConfigs* = object
  pkg*: string
  initFn*: string
  reloadFn*: string

type FileSource* = object
  ns*: CirruData
  run*: CirruData
  defs*: Table[string, CirruData]

const coreNs* = "calcit.core"

# formatting for CirruData

proc toString*(val: CirruData, stringDetail: bool, symbolDetail: bool): string

proc fromListToString(children: seq[CirruData], symbolDetail: bool): string =
  return "(" & children.mapIt(toString(it, true, symbolDetail)).join(" ") & ")"

proc fromSetToString(children: HashSet[CirruData], symbolDetail: bool): string =
  return "#{" & children.mapIt(toString(it, true, symbolDetail)).join(" ") & "}"

proc fromMapToString(children: TernaryTreeMap[CirruData, CirruData], symbolDetail: bool): string =
  let size = children.len()
  if size > 100:
    return "{...(100)...}"
  var tableStr = "{"
  var counted = 0
  for k, child in pairs(children):
    tableStr = tableStr & toString(k, true, symbolDetail) & " " & toString(child, true, symbolDetail)
    counted = counted + 1
    if counted < children.len:
      tableStr = tableStr & ", "
  tableStr = tableStr & "}"
  return tableStr

proc escapeString(x: string): string =
  if x.contains("\"") or x.contains(' '):
    escape("|" & x)
  else:
    "|" & x

proc toString*(val: CirruData, stringDetail: bool, symbolDetail: bool): string =
  case val.kind:
    of crDataBool:
      if val.boolVal:
        "true"
      else:
        "false"
    of crDataNumber:
      if val.numberVal.trunc == val.numberVal:
        $val.numberVal.int
      else:
        $(val.numberVal)
    of crDataString:
      if stringDetail:
        val.stringVal.escapeString
      else:
        val.stringVal
    of crDataList: fromListToString(val.listVal.toSeq, symbolDetail)
    of crDataSet: fromSetToString(val.setVal, symbolDetail)
    of crDataMap: fromMapToString(val.mapVal, symbolDetail)
    of crDataNil: "nil"
    of crDataKeyword: ":" & val.keywordVal[]
    of crDataProc: "<Proc>"
    of crDataFn:
      "<Function: " & val.fnName & " " & $val.fnArgs.toSeq & " " & $val.fnCode & ">"
    of crDataMacro:
      "<Macro: " & val.macroName & " " & $val.macroArgs.toSeq & " " & $val.macroCode & ">"
    of crDataSyntax: "<Syntax>"
    of crDataRecur:
      let content = val.recurArgs.mapIt(it.toString(stringDetail, symbolDetail)).join(" ")
      fmt"<Recur: {content}>"
    of crDataSymbol:
      if symbolDetail:
        val.ns & "/" & escapeString(val.symbolVal)
      else:
        val.symbolVal
    of crDataAtom:
      "<Atom " & val.atomNs & "/" & val.atomDef & " >"

proc `$`*(v: CirruData): string =
  v.toString(false, false)

proc toString*(children: CirruDataScope): string =
  let size = children.len()
  if size > 100:
    return "{...(100)...}"
  var tableStr = "{"
  var counted = 0
  for k, child in pairs(children):
    tableStr = tableStr & k & " " & $child
    counted = counted + 1
    if counted < children.len:
      tableStr = tableStr & ", "
  tableStr = tableStr & "}"
  return tableStr

proc `$`*(children: CirruDataScope): string =
  children.toString

proc `$`*(xs: seq[CirruData]): string =
  return "@[" & xs.map(`$`).join(" ") & "]"

# mutual recursion
proc hash*(value: CirruData): Hash

proc hash*[T](scope: TernaryTreeList[T]): Hash =
  result = hash("ternary-list:")
  for item in scope:
    result = result !& hash(item)
  return result

proc hash*(scope: CirruDataScope): Hash =
  result = hash("scope:")
  for k, v in scope:
    result = result !& hash(k)
    result = result !& hash(v)
  return result

proc hash*(value: CirruData): Hash =
  case value.kind
    of crDataNumber:
      return hash("number:" & $value.numberVal)
    of crDataString:
      return hash("string:" & value.stringVal)
    of crDataNil:
      return hash("nil:")
    of crDataBool:
      return hash("bool:" & $(value.boolVal))
    of crDataKeyword:
      return hash("keyword:" & value.keywordVal[])
    of crDataProc:
      result = hash("proc:")
      result = result !& hash(value.procVal)
      result = !$ result
    of crDataFn:
      result = hash("fn:")
      result = result !& hash(value.fnArgs)
      result = result !& hash(value.fnCode)
      result = result !& hash(value.fnScope)
      result = !$ result
    of crDataSyntax:
      result = hash("syntax:")
      result = result !& hash(value.syntaxVal)
      result = !$ result
    of crDataMacro:
      result = hash("macro:")
      result = result !& hash(value.macroArgs)
      result = result !& hash(value.macroCode)
      result = !$ result
    of crDataList:
      result = hash("list:")
      for x in value.listVal:
        result = result !& hash(x)
      result = !$ result
    of crDataSet:
      result = hash("set:")
      for x in value.setVal.items:
        result = result !& hash(x)
      result = !$ result
    of crDataMap:
      result = hash("map:")
      for k, v in value.mapVal.pairs:
        result = result !& hash(k)
        result = result !& hash(v)

      result = !$ result

    of crDataSymbol:
      result = hash("symbol:")
      result = result !& hash(value.symbolVal)
      result = !$ result
    of crDataRecur:
      result = hash("recur:")
      result = result !& hash(value.recurArgs)
      result = !$ result

    of crDataAtom:
      result = hash("atom:")
      result = result !& hash(value.atomNs)
      result = result !& hash(value.atomDef)
      result = !$ result

proc `==`*(x, y: CirruData): bool =
  if x.kind != y.kind:
    return false
  else:
    case x.kind:
    of crDataNil:
      return true
    of crDataBool:
      return x.boolVal == y.boolVal
    of crDataString:
      return x.stringVal == y.stringVal
    of crDataNumber:
      return x.numberVal == y.numberVal
    of crDataKeyword:
      return x.keywordVal == y.keywordVal
    of crDataProc:
      return x.procVal == y.procVal
    of crDataFn:
      return x.fnArgs == y.fnArgs and x.fnCode == y.fnCode and x.fnScope == y.fnScope
    of crDataMacro:
      return x.macroArgs == y.macroArgs and x.macroCode == y.macroCode
    of crDataSyntax:
      return x.syntaxVal == y.syntaxVal

    of crDataList:
      if x.listVal.len != y.listVal.len:
        return false

      for idx, xi in x.listVal:
        if xi != y.listVal[idx]:
          return false
      return true

    of crDataSet:
      if x.setVal.len != y.setVal.len:
        return false

      for xi in x.setVal.items:
        if not y.setVal.contains(xi):
          return false
      return true

    of crDataMap:
      if x.mapVal.len != y.mapVal.len:
        return false

      for k, v in x.mapVal.pairs:
        if not (y.mapVal.contains(k) and y.mapVal[k].get == v):
          return false

      return true

    of crDataSymbol:
      # TODO, ns not compared, not decided
      return x.symbolVal == y.symbolVal

    of crDataRecur:
      return x.recurArgs == y.recurArgs

    of crDataAtom:
      return x.atomNs == y.atomNs and x.atomDef == y.atomDef
