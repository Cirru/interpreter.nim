
import lists
import strutils
import tables

import ternary_tree
import cirru_edn

import ./types
import ./to_json

type StackInfo* = object
  ns*: string
  def*: string
  code*: CirruData
  args*: seq[CirruData]

var defStack*: DoublyLinkedList[StackInfo]

proc reversed*[T](s: seq[T]): seq[T] =
  result = newSeq[T](s.len)
  for i in 0 .. s.high: result[s.high - i] = s[i]

proc reversed*[T](s: DoublyLinkedList[T]): DoublyLinkedList[T] =
  for i in s:
    result.prepend i

proc pushDefStack*(x: StackInfo): void =
  defStack.append x

proc pushDefStack*(node: CirruData, code: CirruData, args: seq[CirruData]): void =
  if node.kind == crDataSymbol:
    pushDefStack(StackInfo(ns: node.ns, def: node.symbolVal, code: code, args: args))
  else:
    pushDefStack(StackInfo(ns: "??", def: "??", code: code, args: args))

proc popDefStack*(): void =
  defStack.remove defStack.tail

proc showStack*(): void =
  # let errorStack = reversed(defStack)

  var infoList: seq[CirruEdnValue]

  for item in defStack:
    echo item.ns, "/", item.def

    var infoItem = initTable[CirruEdnValue, CirruEdnValue]()
    infoItem[CirruEdnValue(kind: crEdnKeyword, keywordVal: "def")] =
      CirruEdnValue(kind: crEdnString, stringVal: item.ns & "/" & item.def)
    infoItem[CirruEdnValue(kind: crEdnKeyword, keywordVal: "code")] =
      CirruEdnValue(kind: crEdnQuotedCirru, quotedVal: item.code.toCirruNode)

    var ys: seq[CirruEdnValue]
    for ax in item.args:
      ys.add ax.toEdn
    infoItem[CirruEdnValue(kind: crEdnKeyword, keywordVal: "args")] =
      CirruEdnValue(kind: crEdnVector, vectorVal: ys)

    infoList.add CirruEdnValue(kind: crEdnMap, mapVal: infoItem)

  let details = CirruEdnValue(kind: crEdnVector, vectorVal: infoList).formatToCirru(true)

  writeFile "./.calcit-error.cirru", details
  echo "\nMore error details in .calcit-error.cirru     <--------="

var traceFnNs: string
var traceFnName: string
var traceStackSize* = 0

proc matchesTraceFn*(ns: string, def: string): bool =
  traceFnNs == ns and traceFnName == def

proc setTraceFn*(ns: string, def: string) =
  traceFnNs = ns
  traceFnName = def

proc getTraceIndentation*(): string =
  repeat("  ", traceStackSize)
