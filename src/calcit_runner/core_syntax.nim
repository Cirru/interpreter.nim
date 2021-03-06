
import strformat
import system
import tables
import hashes
import options

import ternary_tree

import ./data
import ./types
import ./util/errors
import ./eval/atoms
import ./eval/expression

proc nativeIf*(exprList: seq[CirruData], interpret: FnInterpret, scope: CirruDataScope, ns: string): CirruData =
  if (exprList.len < 2):
    raiseEvalError(fmt"Too few arguments for if", exprList)

  var condition: bool # any values other than false and nil are treated as true
  let node = exprList[0]
  let cond = interpret(node, scope, ns)
  if cond.kind == crDataNil:
    condition = false
  elif cond.kind == crDataBool:
    condition = cond.boolVal
  else:
    condition = true

  if (exprList.len == 2):
    if condition:
      return interpret(exprList[1], scope, ns)
    else:
      return CirruData(kind: crDataNil)
  elif (exprList.len == 3):
    if condition:
      return interpret(exprList[1], scope, ns)
    else:
      return interpret(exprList[2], scope, ns)
  else:
    raiseEvalError("Too many arguments for if", exprList)

proc nativeComment(exprList: seq[CirruData], interpret: FnInterpret, scope: CirruDataScope, ns: string): CirruData =
  return CirruData(kind: crDataNil)

proc nativeDefn(exprList: seq[CirruData], interpret: FnInterpret, scope: CirruDataScope, ns: string): CirruData =
  if exprList.len < 2: raiseEvalError("Expects name and args for defn", exprList)
  let fnName = exprList[0]
  if fnName.kind != crDataSymbol: raiseEvalError("Expects fnName to be string", exprList)
  let argsList = exprList[1]
  if argsList.kind != crDataList: raiseEvalError("Expects args to be list", exprList)
  return CirruData(kind: crDataFn, fnNs: ns, fnName: fnName.symbolVal, fnArgs: argsList.listVal, fnCode: exprList[2..^1], fnScope: scope)

proc nativeLet(exprList: seq[CirruData], interpret: FnInterpret, scope: CirruDataScope, ns: string): CirruData =
  var letScope = scope
  if exprList.len < 1:
    raiseEvalError("No enough code for &let, too short", exprList)
  let pair = exprList[0]
  let body = exprList[1..^1]
  if pair.kind != crDataList:
    raiseEvalError("Expect binding in a list", pair)
  if pair.len != 2:
    raiseEvalError("Expect binding in length 2", pair)
  let name = pair[0]
  let value = pair[1]
  if name.kind != crDataSymbol:
    raiseEvalError("Expecting binding name in string", name)
  letScope = letScope.assoc(name.symbolVal, interpret(value, letScope, ns))
  result = CirruData(kind: crDataNil)
  for child in body:
    result = interpret(child, letScope, ns)

proc nativeDo*(exprList: seq[CirruData], interpret: FnInterpret, scope: CirruDataScope, ns: string): CirruData =
  result = CirruData(kind: crDataNil)
  for child in exprList:
    result = interpret(child, scope, ns)

proc nativeQuote(exprList: seq[CirruData], interpret: FnInterpret, scope: CirruDataScope, ns: string): CirruData =
  if exprList.len != 1:
    raiseEvalError("quote expects 1 argument", exprList)
  return exprList[0]

proc nativeQuoteReplace(exprList: seq[CirruData], interpret: FnInterpret, scope: CirruDataScope, ns: string): CirruData =
  # echo "Calling replace for ", exprList
  if exprList.len != 1:
    raiseEvalError(fmt"quote-replace expects 1 argument, got {exprList.len}", exprList)

  let ret = replaceExpr(exprList[0], interpret, scope, ns)
  if not checkExprStructure(ret):
    raiseEvalError("Unexpected structure from quote-replace", ret)
  ret

proc nativeDefMacro(exprList: seq[CirruData], interpret: FnInterpret, scope: CirruDataScope, ns: string): CirruData =
  let macroName = exprList[0]
  if macroName.kind != crDataSymbol: raiseEvalError("Expects macro name a symbol", exprList)
  let argsList = exprList[1]
  if argsList.kind != crDataList: raiseEvalError("Expects macro args to be a list", exprList)
  return CirruData(
    kind: crDataMacro,
    macroName: macroName.symbolVal, macroNs: ns,
    macroArgs: argsList.listVal, macroCode: exprList[2..^1]
  )

proc nativeDefAtom(exprList: seq[CirruData], interpret: FnInterpret, scope: CirruDataScope, ns: string): CirruData =
  if exprList.len != 2:
    raiseEvalError("assert expects 2 arguments", exprList)
  let name = exprList[0]
  if name.kind != crDataSymbol: raiseEvalError("Expects a symbol for atom", exprList)
  let attempt = getAtomByPath(name.ns, name.symbolVal)
  if attempt.isNone:
    let value = interpret(exprList[1], scope, ns)
    setAtomByPath(name.ns, name.symbolVal, value)
  CirruData(kind: crDataAtom, atomNs: name.ns, atomDef: name.symbolVal)

proc loadCoreSyntax*(programData: var Table[string, ProgramFile], interpret: FnInterpret) =
  programData[coreNs].defs["quote-replace"] = CirruData(kind: crDataSyntax, syntaxVal: nativeQuoteReplace)
  programData[coreNs].defs["defmacro"] = CirruData(kind: crDataSyntax, syntaxVal: nativeDefMacro)
  programData[coreNs].defs[";"] = CirruData(kind: crDataSyntax, syntaxVal: nativeComment)
  programData[coreNs].defs["do"] = CirruData(kind: crDataSyntax, syntaxVal: nativeDo)
  programData[coreNs].defs["if"] = CirruData(kind: crDataSyntax, syntaxVal: nativeIf)
  programData[coreNs].defs["defn"] = CirruData(kind: crDataSyntax, syntaxVal: nativeDefn)
  programData[coreNs].defs["&let"] = CirruData(kind: crDataSyntax, syntaxVal: nativeLet)
  programData[coreNs].defs["quote"] = CirruData(kind: crDataSyntax, syntaxVal: nativeQuote)
  programData[coreNs].defs["defatom"] = CirruData(kind: crDataSyntax, syntaxVal: nativeDefAtom)
