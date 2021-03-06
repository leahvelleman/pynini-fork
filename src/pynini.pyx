#cython: nonecheck=True
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Copyright 2017 and onwards Google, Inc.
#
# For general information on the Pynini grammar compilation library, see
# pynini.opengrm.org.


"""Pynini: finite-state grammar compilation for Python.

Pynini is an experimental Python module which implements compilation of
grammars as finite-state transducers (FSTs).

This module is designed to be wildcard-import-safe.
"""


## IMPLEMENTATION.

## Cython imports. Sorry. There are a lot.

from cython.operator cimport address as addr       # &foo
from cython.operator cimport dereference as deref  # *foo
from cython.operator cimport preincrement as inc   # ++foo

from libcpp cimport bool
from libcpp.memory cimport shared_ptr
from libcpp.memory cimport unique_ptr
from libcpp.utility cimport pair
from libcpp.vector cimport vector

from basictypes cimport int32
from basictypes cimport int64
from basictypes cimport uint64

from fst cimport CLOSURE_PLUS
from fst cimport CLOSURE_STAR
from fst cimport ILABEL_SORT
from fst cimport OLABEL_SORT

from fst cimport ArcSort
from fst cimport Closure
from fst cimport ComposeOptions
from fst cimport Equal
from fst cimport FstClass
from fst cimport LabelFstClassPair
from fst cimport MutableFstClass
from fst cimport ReplaceLabelType
from fst cimport ReplaceOptions
from fst cimport VectorFstClass
from fst cimport WeightClass

from fst cimport kAcceptor
from fst cimport kDelta
from fst cimport kIDeterministic
from fst cimport kError
from fst cimport kNoEpsilons
from fst cimport kNoStateId
from fst cimport kString
from fst cimport kUnweighted

from libcpp.string cimport string

from memory cimport static_pointer_cast

from pywrapfst cimport _Fst
from pywrapfst cimport _MutableFst
from pywrapfst cimport _SymbolTable
from pywrapfst cimport FarReader
from pywrapfst cimport FarWriter
from pywrapfst cimport SymbolTable_ptr
from pywrapfst cimport Weight as _Weight

from pywrapfst cimport _get_WeightClass_or_One
from pywrapfst cimport _get_WeightClass_or_Zero
from pywrapfst cimport _get_compose_filter
from pywrapfst cimport _get_queue_type
from pywrapfst cimport _get_replace_label_type
from pywrapfst cimport _init_MutableFst
from pywrapfst cimport _read_Fst
from pywrapfst cimport _deserialize_Fst
from pywrapfst cimport tostring

# C++ code from fst_util.

from fst_util cimport CompileString
from fst_util cimport Containment
from fst_util cimport FLAGS_fst_relabel_symbol_conflicts
from fst_util cimport CrossProduct
from fst_util cimport GetStringTokenType
from fst_util cimport LenientlyCompose
from fst_util cimport MergeSymbols
from fst_util cimport Optimize
from fst_util cimport OptimizeDifferenceRhs
from fst_util cimport PrintString
from fst_util cimport Repeat
from fst_util cimport StringFile
from fst_util cimport StringMap
from fst_util cimport StringPair
from fst_util cimport StringPathsClass

from fst_util cimport MergeSymbolsType
from fst_util cimport MERGE_INPUT_AND_OUTPUT_SYMBOLS
from fst_util cimport MERGE_LEFT_OUTPUT_AND_RIGHT_INPUT_SYMBOLS

from fst_util cimport StringTokenType
from fst_util cimport SYMBOL

# C++ code for Pynini not from fst_util.

from pynini_includes cimport StringFstClassPair

from pynini_includes cimport MPdtCompose
from pynini_includes cimport MPdtComposeOptions
from pynini_includes cimport MPdtExpand
from pynini_includes cimport MPdtExpandOptions
from pynini_includes cimport MPdtReverse
from pynini_includes cimport PdtCompose
from pynini_includes cimport PdtComposeOptions
from pynini_includes cimport PdtExpand
from pynini_includes cimport PdtExpandOptions
from pynini_includes cimport PdtReverse
from pynini_includes cimport PdtShortestPath
from pynini_includes cimport PdtShortestPathOptions
from pynini_includes cimport PyniniCDRewrite
from pynini_includes cimport PyniniPdtReplace
from pynini_includes cimport PyniniReplace
from pynini_includes cimport ReadLabelPairs
from pynini_includes cimport ReadLabelTriples
from pynini_includes cimport WriteLabelPairs
from pynini_includes cimport WriteLabelTriples

from pynini_includes cimport GetCDRewriteDirection
from pynini_includes cimport CDRewriteDirection

from pynini_includes cimport GetCDRewriteMode
from pynini_includes cimport CDRewriteMode

from pynini_includes cimport GetPdtComposeFilter
from pynini_includes cimport PdtComposeFilter
from pynini_includes cimport EXPAND_FILTER

from pynini_includes cimport GetPdtParserType
from pynini_includes cimport PdtParserType


# Python imports needed for implementation.


import functools

from pywrapfst import FstArgError
from pywrapfst import FstIOError
from pywrapfst import FstOpError

import pywrapfst

import logging

# Python imports needed for 2/3 compatibility.

import collections

import six

# Constants


cdef uint64 kAcceptorAndString = kAcceptor | kString
cdef uint64 kDifferenceRhs = kAcceptor | kUnweighted


# Custom exceptions.


class FstStringCompilationError(FstArgError, ValueError):

  pass


class FstSymbolTableMergeError(FstOpError, ValueError):

  pass


# Helper functions.


cdef StringTokenType _get_token_type(const string &token_type) except *:
  """Matches string with the appropriate StringTokenType enum value.

  This function takes a string argument and returns the matching StringTokenType
  enum value used by StringMap, StringPathsClass and PrintString.

  Args:
    token_type: A string matching a known token type.

  Returns:
    A StringTokenType enum value.

  Raises:
    FstArgError: Unknown token type.

  This function is not visible to Python users.
  """
  cdef StringTokenType token_type_enum
  if not GetStringTokenType(token_type, addr(token_type_enum)):
    raise FstArgError("Unknown token type: {!r}".format(token_type))
  return token_type_enum


cdef CDRewriteDirection _get_cdrewrite_direction(
    const string &rewrite_direction) except *:
  """Matches string with the appropriate CDRewriteDirection enum value.

  This function takes a string argument and returns the matching
  CDRewriteDirection enum value used by PyniniCDRewrite.

  Args:
    rewrite_direction: A string matching a known rewrite direction type.

  Returns:
    A CDRewriteDirection enum value.

  Raises:
    FstArgError: Unknown context-dependent rewrite direction.

  This function is not visible to Python users.
  """
  cdef CDRewriteDirection rewrite_direction_enum
  if not GetCDRewriteDirection(rewrite_direction, addr(rewrite_direction_enum)):
    raise FstArgError(
        "Unknown context-dependent rewrite direction: {!r}".format(
            rewrite_direction))
  return rewrite_direction_enum


cdef CDRewriteMode _get_cdrewrite_mode(const string &rewrite_mode) except *:
  """Matches string with the appropriate CDRewriteMode enum value.

  This function takes a string argument and returns the matching
  CDRewriteMode enum value used by PyniniCDRewrite.

  Args:
    rewrite_mode: A string matching a known rewrite mode type.

  Returns:
    A CDRewriteMode enum value.

  Raises:
    FstArgError: Unknown context-dependent rewrite mode.

  This function is not visible to Python users.
  """
  cdef CDRewriteMode rewrite_mode_enum
  if not GetCDRewriteMode(rewrite_mode, addr(rewrite_mode_enum)):
    raise FstArgError(
        "Unknown context-dependent rewrite mode: {!r}".format(rewrite_mode))
  return rewrite_mode_enum


cdef PdtComposeFilter _get_pdt_compose_filter(
    const string &compose_filter) except *:
  """Matches string with the appropriate PdtComposeFilter enum value.

  Args:
    compose_filter: A string matching a known PdtComposeFilter type.

  Returns:
    A PdtComposeFilter enum value.

  Raises:
    FstArgError: Unknown PDT compose filter type.

  This function is not visible to Python users.
  """
  cdef PdtComposeFilter compose_filter_enum
  if not GetPdtComposeFilter(compose_filter, addr(compose_filter_enum)):
    raise FstArgError("Unknown PDT compose filter type: {!r}".format(
        compose_filter))
  return compose_filter_enum


cdef PdtParserType _get_pdt_parser_type(const string &parser_type) except *:
  """Matches string with the appropriate PdtParserType enum value.

  This function takes a string argument and returns the matching PdtParserType
  enum value used by PyniniPdtReplace.

  Args:
    parser_type: A string matching a known parser type.

  Returns:
    A PdtParserType enum value.

  Raises:
    FstArgError: Unknown PDT parser type.

  This function is not visible to Python users.
  """
  cdef PdtParserType parser_type_enum
  if not GetPdtParserType(parser_type, addr(parser_type_enum)):
    raise FstArgError("Unknown PDT parser type: {!r}".format(parser_type))
  return parser_type_enum


cdef void _add_parentheses_symbols(MutableFstClass *fst,
                                   const vector[pair[int64, int64]] &parens,
                                   bool left) except *:
  """Adds missing parentheses symbols to (M)PDTs.

  Args:
    fst: A pointer to the MutableFstClass to be modified.
    parens: A reference to the underlying parentheses vector.
    left: Was the input FST the left side of a MPDT or PDT composition?

  Raises:
    FstSymbolTableMergeError: Unable to resolve parentheses symbol table
        conflict.
    KeyError.

  This function is not visible to Python users.
  """
  cdef SymbolTable_ptr source_syms
  cdef SymbolTable_ptr sink_syms
  cdef size_t i = 0
  cdef int64 label
  cdef string symbol
  if left:
    source_syms = fst.MutableInputSymbols()
    if source_syms == NULL:
      return
    sink_syms = fst.MutableOutputSymbols()
    if sink_syms == NULL:
      return
  else:
    source_syms = fst.MutableOutputSymbols()
    if source_syms == NULL:
      return
    sink_syms = fst.MutableInputSymbols()
    if sink_syms == NULL:
      return
  for i in xrange(parens.size()):
    label = parens[i].first
    symbol = source_syms.FindSymbol(label)
    if symbol == b"":
      raise KeyError(label)
    if label != sink_syms.AddSymbol(symbol, label):
      raise FstSymbolTableMergeError(
          "Unable to resolve parentheses symbol table conflict")
    label = parens[i].second
    symbol = source_syms.FindSymbol(label)
    if symbol == b"":
      raise KeyError(label)
    if label != sink_syms.AddSymbol(symbol, label):
      raise FstSymbolTableMergeError(
          "Unable to resolve parentheses symbol table conflict")


cdef void _maybe_arcsort(MutableFstClass *ifst1, MutableFstClass *ifst2):
  """Arc-sorts two FST arguments for composition, if necessary.

  Args:
    ifst1: A pointer to the left-hand MutableFstClass.
    ifst2: A pointer to the right-hand MutableFstClass.

  This function is not visible to Python users.
  """
  # It is probably much quicker to force recomputation of the property (if
  # necessary) to call the underlying sort on a vector of arcs.
  if ifst1.Properties(O_LABEL_SORTED, True) != O_LABEL_SORTED:
    ArcSort(ifst1, OLABEL_SORT)
  if ifst2.Properties(I_LABEL_SORTED, True) != I_LABEL_SORTED:
    ArcSort(ifst2, ILABEL_SORT)


# Class for FSTs created from within Pynini. It overrides instance methods of
# the superclass which take an FST argument so that it can string-compile said
# argument if it is not yet an FST. It also overloads binary == (equals),
# * (composition), # + (concatenation), and | (union).


cdef class Fst(_MutableFst):

  """
  Fst(arc_type="standard")

  This class wraps a mutable FST and exposes all destructive methods.

  Args:
    arc_type: An optional string indicating the arc type for the FST.
  """

  cdef void _from_MutableFstClass(self, MutableFstClass *tfst):
    """
    _from_MutableFstClass(tfst)

    Constructs a Pynini Fst by taking ownership of a MutableFstClass pointer.

    This method is not visible to Python users.
    """
    self._fst.reset(tfst)
    self._mfst = static_pointer_cast[MutableFstClass, FstClass](self._fst)

  def __init__(self, arc_type=b"standard"):
    cdef VectorFstClass *tfst = new VectorFstClass(<string> tostring(arc_type))

    if tfst.Properties(kError, True) == kError:
       raise FstArgError("Unknown arc type: {!r}".format(arc_type))
    self._from_MutableFstClass(tfst)

  @classmethod
  def from_pywrapfst(cls, _Fst ifst):
    """
    Fst.from_pywrapfst(ifst)

    Constructs a Pynini FST from a pywrapfst._Fst.

    This class method converts an FST from the pywrapfst module (pywrapfst._Fst
    or its subclass pywrapfst._MutableFst) to a Pynini.Fst. This is essentially
    a downcasting operation which grants the object additional instance methods,
    including an enhanced `closure`, `paths`, and `stringify`. The input FST is
    not invalidated, but mutation of the input or output object while the other
    is still in scope will trigger a deep copy.

    Args:
      ifst: Input FST of type pywrapfst._Fst.

    Returns:
      An FST.
    """
    cdef Fst result = Fst.__new__(Fst)
    result._from_MutableFstClass(
        new VectorFstClass(<FstClass> deref(ifst._fst)))
    return result

  @classmethod
  def read(cls, filename):
    """
    Fst.read(filename)

    Reads an FST from a file.

    Args:
      filename: The string location of the input file.

    Returns:
      An FST.

    Raises:
      FstIOError: Read failed.
      FstOpError: Read-time conversion failed.
    """
    return _init_Fst_from_MutableFst(_read_Fst(filename, fst_type=b"vector"))

  @classmethod
  def read_from_string(cls, fst_string, fst_type=None):
    """
    """
    return _init_Fst_from_MutableFst(_deserialize_Fst(fst_string, fst_type))

  cpdef StringPaths paths(self, input_token_type=b"byte",
                          output_token_type=b"byte", bool rm_epsilon=True):
    """
    paths(self, token_type="byte)

    Creates iterator over all string paths in an acyclic FST.

    This method returns an iterator over all paths (represented as pairs of
    strings and an associated path weight) through an acyclic FST. This
    operation is only feasible when the FST is acyclic. Depending on the
    requested token type, the arc labels along the input and output sides of a
    path are interpreted as UTF-8-encoded Unicode strings, raw bytes, or a
    concatenation of string labels from a symbol table.

    Args:
      input_token_type: A string indicating how the input strings are to be
          constructed from arc labels---one of: "byte" (interprets arc labels
          as raw bytes), "utf8" (interprets arc labels as Unicode code points),
          or "symbol" (interprets arc labels using the input symbol table).
      output_token_type: A string indicating how the output strings are to be
          constructed from arc labels---one of: "byte" (interprets arc labels
          as raw bytes), "utf8" (interprets arc labels as Unicode code points),
          or "symbol" (interprets arc labels using the input symbol table).
      rm_epsilon: Should epsilons be removed?

    Raises:
      FstArgError: Unknown token type.
      FstArgError: FST is not acyclic.

    See also: `StringPaths`.
    """
    return StringPaths(self, input_token_type, output_token_type, rm_epsilon)

  cpdef string stringify(self, token_type=b"byte",
                         bool rm_epsilon=True) except *:
    """
    stringify(self, token_type="byte")

    Creates a string from a string FST.

    This method returns the string recognized by the FST as a Python byte or
    Unicode string. This is only well-defined when the FST is an acceptor and a
    "string" FST (meaning that the start state is numbered 0, and there is
    exactly one transition from each state i to each state i + 1, there are no
    other transitions, and the last state is final). Depending on the requested
    token type, the arc labels are interpreted as a UTF-8-encoded Unicode
    string, raw bytes, or as a concatenation of string labels from the output
    symbol table.

    The underlying routine reads only the output labels, so if the FST is
    not an acceptor, it will be treated as the output projection of the FST.

    Args:
      token_type: A string indicating how the string is to be constructed from
          arc labels---one of: "byte" (interprets arc labels as raw bytes),
          "utf8" (interprets arc labels as Unicode code points), or a
          SymbolTable.
      rm_epsilon: Should epsilons be removed?

    Returns:
      The string corresponding to (an output projection) of the FST.

    Raises:
      FstArgError: FST is not a string.
      FstArgError: Unknown token type.
    """
    cdef StringTokenType ttype
    cdef SymbolTable_ptr syms = NULL
    if isinstance(token_type, pywrapfst._SymbolTable):
      ttype = SYMBOL
      syms = (<SymbolTable_ptr> (<_SymbolTable> token_type)._table)
    else:
      ttype = _get_token_type(tostring(token_type))
      if ttype == SYMBOL:
        raise FstArgError("Invalid token type")
    cdef string result
    if not PrintString(deref(self._fst), ttype, addr(result), syms, rm_epsilon):
      raise FstArgError("FST is not a string")
    return result

  # The following all override their definition in _MutableFst.

  cpdef Fst copy(self):
    """
    copy(self)

    Makes a copy of the FST.
    """
    return _init_Fst_from_MutableFst(super(_MutableFst, self).copy())

  def closure(self, int32 lower=0, int32 upper=0):
    """
    closure(self, lower)
    closure(self, lower, upper)

    Computes concatenative closure.

    This operation destructively converts the FST to its concatenative closure.
    If A transduces string x to y with weight w, then the zero-argument form
    `A.closure()` mutates A so that it transduces between empty strings with
    weight 1, transduces string x to y with weight w, transduces xx to yy with
    weight w \otimes w, string xxx to yyy with weight w \otimes w \otimes w
    (and so on).

    When called with two optional positive integer arguments, these act as
    lower and upper bounds, respectively, for the number of cycles through the
    original FST that the mutated FST permits. Therefore, `A.closure(0, 1)`
    mutates A so that it permits 0 or 1 cycles; i.e., the mutated A transduces
    between empty strings or transduces x to y.

    When called with one optional positive integer argument, this argument
    acts as the lower bound, with the upper bound implicitly set to infinity.
    Therefore, `A.closure(1)` performs a mutation roughly equivalent to
    `A.closure()` except that the former does not transduce between empty
    strings.

    The following are the equivalents for the closure-style syntax used in
    Perl-style regular expressions:

    Regexp:\t\tThis method:\t\tCopy shortcuts:

    /x?/\t\tx.closure(0, 1)\t\tx.ques
    /x*/\t\tx.closure()\t\tx.star
    /x+/\t\tx.closure(1)\t\tx.plus
    /x{N}/\t\tx.closure(N, N)
    /x{M,N}/\t\tx.closure(M, N)
    /x{N,}/\t\tx.closure(N)
    /x{,N}/\t\tx.closure(0, N)

    Args:
      lower: lower bound.
      upper: upper bound.

    Returns:
      self.

    See also `ques`, `star`, `plus`.
    """
    Repeat(self._mfst.get(), lower, upper)
    self._check_mutating_imethod()
    return self

  @property
  def plus(self):
    """
    plus(self)

    Constructively computes +-closure.

    Returns:
      Closure-d copy.

    See also: `closure`.
    """
    cdef Fst result = self.copy()
    Closure(result._mfst.get(), CLOSURE_PLUS)
    result._check_mutating_imethod()
    return result

  @property
  def ques(self):
    """
    ques(self)

    Constructively computes ?-closure.

    Returns:
      Closure-d copy.

    See also: `closure`.
    """
    cdef Fst result = self.copy()
    Repeat(result._mfst.get(), 0, 1)
    result._check_mutating_imethod()
    return result

  @property
  def star(self):
    """
    star(self)

    Constructively computes *-closure.

    Returns:
      Closure-d copy.

    See also: `closure`.
    """
    cdef Fst result = self.copy()
    Closure(result._mfst.get(), CLOSURE_STAR)
    result._check_mutating_imethod()
    return result

  def concat(self, ifst):
    """
    concat(self, ifst)

    Computes the concatenation (product) of two FSTs.

    This operation destructively concatenates the FST with a second FST. If A
    transduces string x to y with weight a and B transduces string w to v with
    weight b, then their concatenation transduces string xw to yv with weight
    a \otimes b.

    Args:
      ifst: The second input FST.

    Returns:
      self.

    Raises:
      FstOpError: Operation failed.
      FstSymbolTableMergeError: Unable to resolve symbol table conflict
          without relabeling.
    """
    cdef Fst rhs = _compile_or_copy_Fst(ifst, arc_type=self.arc_type())
    if not MergeSymbols(self._mfst.get(), rhs._mfst.get(),
                        MERGE_INPUT_AND_OUTPUT_SYMBOLS):
     if not FLAGS_fst_relabel_symbol_conflicts:
       raise FstSymbolTableMergeError(
           "Unable to resolve symbol table conflict without relabeling")
     else:
       raise FstOpError("Operation failed")
    self._concat(rhs)
    return self

  cdef void _optimize(self, bool compute_props=False) except *:
    Optimize(self._mfst.get(), compute_props)
    self._check_mutating_imethod()

  def optimize(self, bool compute_props=False):
    """
    optimize(self, compute_props=False)

    Performs a generic optimization of the FST.

    This operation destructively optimizes the FST using epsilon-removal,
    arc-sum mapping, determinization, and minimization (where possible). The
    algorithm is as follows:

    * If the FST is not (known to be) epsilon-free, perform epsilon-removal.
    * Combine identically labeled multi-arcs and sum their weights.
    * If the FST does not have idempotent weights, halt.
    * If the FST is not (known to be) deterministic:
      - If the FST is a (known) acceptor:
        * If the FST is not (known to be) unweighted and/or acyclic, encode
          weights.
      - Otherwise, encode labels and, if the FST is not (known to be)
        unweighted, encode weights.
      - Determinize the FST.
    * Minimize the FST.
    * Decode the FST and combine identically-labeled multi-arcs and sum their
      weights, if the FST was previously encoded.

    By default, FST properties are not computed if they are not already set.

    This optimization may result in a reduction of size (due to epsilon-removal,
    arc-sum mapping, and minimization) and possibly faster composition, but
    determinization (a prerequisite of minimization) may result in an
    exponential blowup in size in the worst case. Judicious use of optimization
    is a bit of a black art.

    Args:
      compute_props: Should unknown FST properties be computed to help choose
          appropriate optimizations?

    Returns:
      self.
    """
    self._optimize(compute_props)
    return self

  def union(self, ifst):
    """
    union(self, ifst)

    Computes the union (sum) of two FSTs.

    This operation destructively computes the union (sum) of two FSTs. If A
    transduces string x to y with weight a and B transduces string w to v with
    weight b, then their union transduces x to y with weight a and w to v with
    weight b.

    Args:
      ifst: The second input FST.

    Returns:
      self.

    Raises:
      FstOpError: Operation failed.
      FstSymbolTableMergeError: Unable to resolve symbol table conflict
          without relabeling.
    """
    cdef Fst lhs
    cdef Fst rhs
    (lhs, rhs) = _compile_or_copy_two_Fsts(self, ifst)
    if not MergeSymbols(self._mfst.get(), rhs._mfst.get(),
                        MERGE_INPUT_AND_OUTPUT_SYMBOLS):
     if not FLAGS_fst_relabel_symbol_conflicts:
       raise FstSymbolTableMergeError(
           "Unable to resolve symbol table conflict without relabeling")
     else:
       raise FstOpError("Operation failed")
    self._union(rhs)
    return self

  # Operator overloads.

  def __richcmp__(self, other, int op):
    cdef Fst lhs
    cdef Fst rhs
    (lhs, rhs) = _compile_or_copy_two_Fsts(self, other)
    if op == 2:    # ==
      return Equal(deref(lhs._fst), deref(rhs._fst), kDelta)
    elif op == 3:  # !=
      return not Equal(deref(lhs._fst), deref(rhs._fst), kDelta)
    raise NotImplementedError("Operator {} not implemented".format(op))

  # x + y

  def __add__(self, other):
    cdef string arc_type = (self.arc_type() if hasattr(self, "arc_type") else
                            other.arc_type())
    cdef Fst lhs = _compile_or_copy_Fst(self, arc_type=arc_type)
    lhs.concat(other)
    return lhs

  # x - y

  def __sub__(self, other):
    return difference(self, other)

  # x * y

  def __mul__(self, other):
    return compose(self, other)

  # x | y

  def __or__(self, other):
    cdef string arc_type = (self.arc_type() if hasattr(self, "arc_type") else
                            other.arc_type())
    cdef Fst lhs = _compile_or_copy_Fst(self, arc_type=arc_type)
    lhs.union(other)
    return lhs


# Makes a reference-counted copy, if it's already an FST; otherwise, compiles
# it into an acceptor.


cdef Fst _compile_or_copy_Fst(arg, arc_type=b"standard"):
  if not isinstance(arg, Fst):
    return acceptor(arg, arc_type=arc_type)
  else:
    return arg.copy()


# Makes copies or compiles, using the arc type of the first if specified,
# then the arc type of the second, then using the default.


cdef object _compile_or_copy_two_Fsts(arg1, arg2):
  cdef Fst lhs
  cdef Fst rhs
  if isinstance(arg1, Fst):
    lhs = arg1.copy()
    rhs = _compile_or_copy_Fst(arg2, arc_type=arg1.arc_type())
  elif isinstance(arg2, Fst):
    rhs = arg2.copy()
    lhs = acceptor(arg1, arc_type=arg2.arc_type())
  else:
    lhs = acceptor(arg1)
    rhs = acceptor(arg2)
  return (lhs, rhs)


# Down-casts a _MutableFst to a Pynini Fst by taking ownership of the underlying
# pointers of the former.


cdef Fst _init_Fst_from_MutableFst(_MutableFst rhs):
  cdef Fst result = Fst.__new__(Fst)
  result._fst = rhs._fst
  result._mfst = rhs._mfst
  return result


# Functions for FST compilation.


cpdef Fst acceptor(astring,
                   weight=None,
                   arc_type=b"standard",
                   token_type=b"byte"):
  """
  acceptor(astring, weight=None, arc_type="standard", token_type="byte")

  Creates an acceptor from a string.

  This function creates an FST which accepts its input with a fixed weight
  (defaulting to semiring One).

  Args:
    astring: The input string.
    weight: A Weight or weight string indicating the desired path weight. If
        omitted or null, the path weight is set to semiring One.
    arc_type: An optional string indicating the arc type for the compiled FST.
        This argument is silently ignored if istring and/or ostring is already
        compiled.
    token_type: Either a string indicating how the input string is to be
        encoded as arc labels---one of: utf8" (encodes the strings as UTF-8
        encoded Unicode string), "byte" (encodes the string as raw bytes)---or
        a SymbolTable to be used to encode the string.

    Returns:
      An FST acceptor.

    Raises:
      FstArgError: Unknown arc type.
      FstArgError: Unknown token type.
      FstOpError: Operation failed.
      FstStringCompilationError: String compilation failed.
  """
  cdef Fst result = Fst(tostring(arc_type))
  cdef WeightClass wc = _get_WeightClass_or_One(result.weight_type(), weight)
  cdef StringTokenType ttype
  cdef SymbolTable_ptr syms = NULL
  if isinstance(token_type, pywrapfst._SymbolTable):
    ttype = SYMBOL
    syms = (<SymbolTable_ptr> (<_SymbolTable> token_type)._table)
  else:
    ttype = _get_token_type(tostring(token_type))
  cdef bool success = CompileString(tostring(astring), wc, ttype,
                                    result._mfst.get(), syms)
  # First we check whether there were problems with arc or weight type, then
  # for string compilation issues.
  result._check_mutating_imethod()
  if not success:
    raise FstStringCompilationError("String compilation failed")
  return result


cpdef Fst transducer(istring,
                     ostring,
                     weight=None,
                     arc_type=b"standard",
                     input_token_type=b"byte",
                     output_token_type=b"byte"):
  """
  transducer(istring, ostring, weight=None, arc_type="standard",
             input_token_type="byte", output_token_type="byte")

  Creates a transducer from a pair of strings or acceptor FSTs.

  This function creates an FST which transduces from the first string to
  the second with a fixed weight (defaulting to semiring One). If one or both
  of the input arguments is already compiled as an FST, the resulting transducer
  is simply the cross-product between the language accepted by the upper and
  lower FSTs.

  Args:
    istring: The input string, or an acceptor FST representing the upper
        language.
    ostring: The output string, or an acceptor FST representing the upper
        language.
    weight: A Weight or weight string indicating the desired path weight. If
        omitted or null, the path weight is set to semiring One. This argument
        is silently ignored if istring and/or ostring is already compiled.
    arc_type: An optional string indicating the arc type for the compiled FST.
        This argument is silently ignored if istring and/or ostring is already
        compiled.
    input_token_type: Either a string indicating how the upper string is to be
        encoded as arc labels---one of: utf8" (encodes the strings as UTF-8
        encoded Unicode string), "byte" (encodes the string as raw bytes)---or
        a SymbolTable to be used to encode the string.
    output_token_type: Either a string indicating how the lower string is to be
        encoded as arc labels---one of: utf8" (encodes the strings as UTF-8
        encoded Unicode string), "byte" (encodes the string as raw bytes)---or
        a SymbolTable to be used to encode the string.

  Returns:
    An FST transducer.

  Raises:
    FstArgError: Unknown arc type.
    FstArgError: Unknown token type.
    FstArgError: Weight types do not match.
    FstOpError: Operation failed.
    FstStringCompilationError: String compilation failed.
  """
  cdef Fst lower
  cdef Fst upper
  cdef Fst result = Fst(arc_type)
  # Sets up upper language.
  if not isinstance(istring, Fst):
    upper = acceptor(istring, arc_type=arc_type, token_type=input_token_type)
  else:
    upper = istring
  if upper._fst.get().Properties(kAcceptor, True) != kAcceptor:
    logging.warning("Expecting acceptor or string argument, got a transducer")
  # Sets up lower language, and passes weight.
  if not isinstance(ostring, Fst):
    lower = acceptor(ostring, arc_type=arc_type, token_type=output_token_type)
  else:
    lower = ostring
    if lower._fst.get().Properties(kAcceptor, True) != kAcceptor:
      logging.warning("Expecting acceptor or string argument, got a transducer")
  # Actually computes cross-product.
  CrossProduct(deref(upper._fst), deref(lower._fst), result._mfst.get(),
               _get_WeightClass_or_One(result.weight_type(), weight))
  result._check_mutating_imethod()
  return result


cpdef Fst cdrewrite(tau,
                    lambda_,
                    rho,
                    sigma_star,
                    direction=b"ltr",
                    mode=b"obl"):
  """
  cdrewrite(tau, lambda, rho, sigma_star, direction="ltr", mode="obl")

  Generates a transducer expressing a context-dependent rewrite rule.

  This operation compiles a transducer representing a context-dependent
  rewrite rule of the form

      phi -> psi / lambda __ rho

  over a finite vocabulary. To apply the resulting transducer, simply compose
  it with an input string or lattice.

  Args:
    tau: A (weighted) transducer representing phi -> psi.
    lambda: An unweighted acceptor representing the left context.
    rho: An unweighted acceptor representing the right context.
    sigma_star: A cyclic, unweighted acceptor representing the closure over the
        alphabet.
    direction: A string specifying the direction of rule application; one of:
        "ltr" (left-to-right application), "rtl" (right-to-left application),
        or "sim" (simultaneous application).
    mode: A string specifying the mode of rule application; one of: "obl"
        (obligatory application), "opt" (optional application).

  Returns:
    A rewrite rule FST.

  Raises:
    FstArgError: Unknown cdrewrite direction type.
    FstArgError: Unknown cdrewrite mode type.
    FstOpError: Operation failed.
  """
  cdef CDRewriteDirection cd = _get_cdrewrite_direction(tostring(direction))
  cdef CDRewriteMode cm = _get_cdrewrite_mode(tostring(mode))
  cdef Fst tau_compiled = _compile_or_copy_Fst(tau)
  cdef string arc_type = tau_compiled.arc_type()
  cdef Fst lambda_compiled = _compile_or_copy_Fst(lambda_, arc_type)
  cdef Fst rho_compiled = _compile_or_copy_Fst(rho, arc_type)
  cdef Fst sigma_star_compiled = _compile_or_copy_Fst(sigma_star, arc_type)
  cdef Fst result = Fst(arc_type)
  PyniniCDRewrite(deref(tau_compiled._fst), deref(lambda_compiled._fst),
                  deref(rho_compiled._fst), deref(sigma_star_compiled._fst),
                  result._mfst.get(), cd, cm)
  result._check_mutating_imethod()
  if not result.num_states():
    logging.warning("Compiled rewrite rule has no connected states")
  return result


cpdef Fst containment(ifst, sigma_star):
  """
  containment(ifst, sigma_star)

  Creates a containment of a transducer with respect to a universal language.

  This operation constructs a transducer consisting of the input FST optionally
  preceded and/or followed by any string from some alphabet.

  Args:
    ifst: The input FST.
    sigma_star: A cyclic, unweighted acceptor representing the closure over the
        alphabet.

  Returns:
    An FST.

  Raises:
    FstOpError: Operation failed.
    FstSymbolTableMergeError: Unable to resolve symbol table conflict without
        relabeling.
  """
  cdef Fst ifst_compiled
  cdef Fst sigma_star_compiled
  (ifst_compiled, sigma_star_compiled) = _compile_or_copy_two_Fsts(ifst,
      sigma_star)
  if not MergeSymbols(ifst_compiled._mfst.get(),
                      sigma_star_compiled._mfst.get(),
                      MERGE_INPUT_AND_OUTPUT_SYMBOLS):
    if not FLAGS_fst_relabel_symbol_conflicts:
      raise FstSymbolTableMergeError(
          "Unable to resolve symbol table conflict without relabeling")
    else:
      raise FstOpError("Operation failed")
  cdef Fst result = Fst(ifst_compiled.arc_type())
  Containment(deref(ifst_compiled._fst), deref(sigma_star_compiled._fst),
              result._mfst.get())
  result._check_mutating_imethod()
  return result


cpdef Fst epsilon_machine(arc_type=b"standard", weight=None):
  """
  epsilon_machine(arc_type="standard")

  Constructs a single-state, no-arc FST accepting epsilon.

  This function creates an unweighted FST with a single state which is both
  initial and final.

  Args:
    arc_type: An optional string indicating the arc type for the compiled FST.
    weight: A Weight or weight string indicating the desired path weight. If
        omitted or null, the path weight is set to semiring One.

  Returns:
    An FST.

  Raises:
    FstArgError: Unknown arc type.
  """
  cdef Fst result = Fst(arc_type)
  cdef int64 state = result._mfst.get().AddState()
  result._mfst.get().SetStart(state)
  result._mfst.get().SetFinal(state,
      _get_WeightClass_or_One(result.weight_type(), weight))
  return result


cpdef Fst leniently_compose(ifst1, ifst2, sigma_star, compose_filter=b"auto",
                            bool connect=True):
  """
  leniently_compose(ifst1, ifst2, compose_filter="auto", connect=True)

  Constructively leniently-composes two FSTs.

  This operation computes the lenient composition of two FSTs. The lenient
  composition of two FSTs the priority union of their composition and the
  left-hand side argument, where priority union is simply union in which the
  left-hand side argument's relations have "priority" over the right-hand side
  argument's relations.

  Args:
    ifst: The input FST.
    sigma_star: A cyclic, unweighted acceptor representing the closure over the
        alphabet.
    compose_filter: A string matching a known composition filter; one of:
        "alt_sequence", "auto", "match", "null", "sequence", "trivial".
    connect: Should output be trimmed?

  Returns:
    A leniently composed FST.

  Raises:
    FstOpError: Operation failed.
    FstSymbolTableMergeError: Unable to resolve symbol table conflict without
        relabeling.
  """
  cdef Fst ifst1_compiled
  cdef Fst ifst2_compiled
  (ifst1_compiled, ifst2_compiled) = _compile_or_copy_two_Fsts(ifst1, ifst2)
  cdef string arc_type = ifst1_compiled.arc_type()
  sigma_star_compiled = _compile_or_copy_Fst(sigma_star, arc_type)
  cdef unique_ptr[ComposeOptions] opts
  opts.reset(new ComposeOptions(connect,
      _get_compose_filter(tostring(compose_filter))))
  cdef Fst result = Fst(arc_type)
  LenientlyCompose(deref(ifst1_compiled._fst), deref(ifst2_compiled._fst),
                   deref(sigma_star_compiled._fst), result._mfst.get(),
                   deref(opts))
  result._check_mutating_imethod()
  if not result.num_states():
    logging.warning("Composed FST has no connected states")
  return result


cpdef Fst string_file(filename,
                      arc_type=b"standard",
                      input_token_type=b"byte",
                      output_token_type=b"byte"):
  """
  string_file(filename, arc_type="standard", input_token_type="byte",
             output_token_type="byte")

  Creates a transducer that maps between elements of mappings read from
  a tab-delimited file.

  Args:
    filename: The path to a file consisting of lines of input/output pairs
        separated by a tab character; if a line element is a epsilon_machine,
        the identity mapping is used.
    arc_type: A string indicating the arc type.
    input_token_type: A string indicating how the input strings are to be
        encoded as arc labels---one of: utf8" (encodes strings as a UTF-8
        encoded Unicode strings), "byte" (encodes strings as raw bytes)---or a
        SymbolTable.
    output_token_type: A string indicating how the output strings are to be
        encoded as arc labels---one of: utf8" (encodes strings as a UTF-8
        encoded Unicode strings), "byte" (encodes strings as raw bytes)---or a
        SymbolTable.

  Returns:
    An FST.

  Raises:
    FstIOError: Read failed.
  """
  cdef StringTokenType itype
  cdef SymbolTable_ptr isyms = NULL
  if isinstance(input_token_type, pywrapfst._SymbolTable):
    itype = SYMBOL
    isyms = (<SymbolTable_ptr> (<_SymbolTable> input_token_type)._table)
  else:
    itype = _get_token_type(tostring(input_token_type))
  cdef StringTokenType otype
  cdef SymbolTable_ptr osyms = NULL
  if isinstance(output_token_type, pywrapfst._SymbolTable):
    osyms = (<SymbolTable_ptr> (<_SymbolTable> output_token_type)._table)
    otype = SYMBOL
  else:
    otype = _get_token_type(tostring(output_token_type))
  cdef Fst result = Fst(arc_type)
  if not StringFile(tostring(filename), itype, otype, result._mfst.get(),
                    isyms, osyms):
    raise FstIOError("Read failed")
  return result


cpdef Fst string_map(pairs,
                     arc_type=b"standard",
                     input_token_type=b"byte",
                     output_token_type=b"byte"):
  """
  string_map(pairs, arc_type="standard", input_token_type="byte",
             output_token_type="byte")

  Creates a transducer that maps between elements of mappings.

  Args:
    pairs: An iterable containing strings. If the iterable implements .iteritems
      or .items, this is used to extract the pairs. If any element of the
      iterable is a string, or an iterable containing exactly one string, the
      identity mapping is used.
    arc_type: A string indicating the arc type.
    input_token_type: A string indicating how the input strings are to be
        encoded as arc labels---one of: utf8" (encodes strings as a UTF-8
        encoded Unicode strings), "byte" (encodes strings as raw bytes)---or a
        SymbolTable.
    output_token_type: A string indicating how the output strings are to be
        encoded as arc labels---one of: utf8" (encodes strings as a UTF-8
        encoded Unicode strings), "byte" (encodes strings as raw bytes)---or a
        SymbolTable.

  Returns:
    An FST.

  Raises:
    FstArgError: Mappings must be of length 1 or 2.
    FstArgError: String map compilation failed.
  """
  cdef StringTokenType itype
  cdef SymbolTable_ptr isyms = NULL
  if isinstance(input_token_type, pywrapfst._SymbolTable):
    itype = SYMBOL
    isyms = (<SymbolTable_ptr> (<_SymbolTable> input_token_type)._table)
  else:
    itype = _get_token_type(tostring(input_token_type))
  cdef StringTokenType otype
  cdef SymbolTable_ptr osyms = NULL
  if isinstance(output_token_type, pywrapfst._SymbolTable):
    otype = SYMBOL
    osyms = (<SymbolTable_ptr> (<_SymbolTable> output_token_type)._table)
  else:
    otype = _get_token_type(tostring(output_token_type))
  cdef Fst result = Fst(arc_type)
  cdef vector[StringPair] new_pairs
  if hasattr(pairs, "iteritems"):
    pairs = pairs.iteritems()
  elif hasattr(pairs, "items"):
    pairs = pairs.items()
  for pair in pairs:
    if isinstance(pair, collections.Iterable) and not isinstance(pair, six.string_types):
      if len(pair) == 2:
        new_pairs.push_back(StringPair(tostring(pair[0]),
                                       tostring(pair[1])))
      elif len(pair) == 1:
        string = tostring(pair[0])
        new_pairs.push_back(StringPair(string, string))
      else:
        raise FstArgError("Mappings must be of length 1 or 2")
    else:
      string = tostring(pair)
      new_pairs.push_back(StringPair(string, string))
  cdef bool success = StringMap(new_pairs, itype, otype,
                                result._mfst.get(), isyms, osyms)
  if not success:
    raise FstArgError("String map compilation failed")
  return result


# Decorator for one-argument constructive FST operations.


def _1arg_patch(fnc):
  @functools.wraps(fnc)
  def patch(arg, *args, **kwargs):
    cdef Fst fst = _compile_or_copy_Fst(arg)
    return _init_Fst_from_MutableFst(fnc(fst, *args, **kwargs))
  return patch


arcmap = _1arg_patch(pywrapfst.arcmap)
determinize = _1arg_patch(pywrapfst.determinize)
disambiguate = _1arg_patch(pywrapfst.disambiguate)
epsnormalize = _1arg_patch(pywrapfst.epsnormalize)
prune = _1arg_patch(pywrapfst.prune)
push = _1arg_patch(pywrapfst.push)
randgen = _1arg_patch(pywrapfst.randgen)
reverse = _1arg_patch(pywrapfst.reverse)
rmepsilon = _1arg_patch(pywrapfst.rmepsilon)
shortestpath = _1arg_patch(pywrapfst.shortestpath)
statemap = _1arg_patch(pywrapfst.statemap)
synchronize = _1arg_patch(pywrapfst.synchronize)


def _shortestdistance_patch(fnc):
  @functools.wraps(fnc)
  def patch(arg, *args, **kwargs):
    cdef Fst fst = _compile_or_copy_Fst(arg)
    return fnc(fst, *args, **kwargs)
  return patch


shortestdistance = _shortestdistance_patch(pywrapfst.shortestdistance)


# Two-argument constructive FST operations. If just one of the two FST
# arguments has been compiled, the arc type of the compiled argument is used to
# determine the arc type of the not-yet-compiled argument.


def _compose_patch(fnc):
  @functools.wraps(fnc)
  def patch(arg1, arg2, *args, **kwargs):
    cdef Fst lhs
    cdef Fst rhs
    (lhs, rhs) = _compile_or_copy_two_Fsts(arg1, arg2)
    if not MergeSymbols(lhs._mfst.get(), rhs._mfst.get(),
                        MERGE_LEFT_OUTPUT_AND_RIGHT_INPUT_SYMBOLS):
     if not FLAGS_fst_relabel_symbol_conflicts:
       raise FstSymbolTableMergeError(
           "Unable to resolve symbol table conflict without relabeling")
     else:
       raise FstOpError("Operation failed")
    _maybe_arcsort(lhs._mfst.get(), rhs._mfst.get())
    lhs = _init_Fst_from_MutableFst(fnc(lhs, rhs, *args, **kwargs))
    if not lhs.num_states():
      logging.warning("Composed FST has no connected states")
    return lhs
  return patch


compose = _compose_patch(pywrapfst.compose)


def _difference_patch(fnc):
  @functools.wraps(fnc)
  def patch(arg1, arg2, *args, **kwargs):
    cdef Fst lhs
    cdef Fst rhs
    (lhs, rhs) = _compile_or_copy_two_Fsts(arg1, arg2)
    if not MergeSymbols(lhs._mfst.get(), rhs._mfst.get(),
                        MERGE_LEFT_OUTPUT_AND_RIGHT_INPUT_SYMBOLS):
     if not FLAGS_fst_relabel_symbol_conflicts:
       raise FstSymbolTableMergeError(
           "Unable to resolve symbol table conflict without relabeling")
     else:
       raise FstOpError("Operation failed")
    if not MergeSymbols(lhs._mfst.get(), rhs._mfst.get(),
                        MERGE_INPUT_AND_OUTPUT_SYMBOLS):
      raise FstSymbolTableMergeError(
          "Unable to resolve symbol table conflict without relabeling")
    if rhs._mfst.get().Properties(kDifferenceRhs, True) != kDifferenceRhs:
      raise FstOpError("2nd argument must be an unweighted acceptor")
    # Makes RHS epsilon-free and deterministic.
    OptimizeDifferenceRhs(rhs._mfst.get(), True)
    return _init_Fst_from_MutableFst(fnc(lhs, rhs, *args, **kwargs))
  return patch


difference = _difference_patch(pywrapfst.difference)


def _intersect_patch(fnc):
  @functools.wraps(fnc)
  def patch(arg1, arg2, *args, **kwargs):
    cdef Fst lhs
    cdef Fst rhs
    (lhs, rhs) = _compile_or_copy_two_Fsts(arg1, arg2)
    if not MergeSymbols(lhs._mfst.get(), rhs._mfst.get(),
                        MERGE_LEFT_OUTPUT_AND_RIGHT_INPUT_SYMBOLS):
     if not FLAGS_fst_relabel_symbol_conflicts:
       raise FstSymbolTableMergeError(
           "Unable to resolve symbol table conflict without relabeling")
     else:
       raise FstOpError("Operation failed")
    if not MergeSymbols(lhs._mfst.get(), rhs._mfst.get(),
                        MERGE_INPUT_AND_OUTPUT_SYMBOLS):
      raise FstSymbolTableMergeError(
          "Unable to resolve symbol table conflict without relabeling")
    return _init_Fst_from_MutableFst(fnc(lhs, rhs, *args, **kwargs))
  return patch


intersect = _intersect_patch(pywrapfst.intersect)


# Simple comparison operations.


def _comp_patch(fnc):
  @functools.wraps(fnc)
  def patch(arg1, arg2, *args, **kwargs):
    cdef Fst lhs
    cdef Fst rhs
    (lhs, rhs) = _compile_or_copy_two_Fsts(arg1, arg2)
    return fnc(lhs, rhs, *args, **kwargs)
  return patch


equal = _comp_patch(pywrapfst.equal)
isomorphic = _comp_patch(pywrapfst.isomorphic)


# Comparison operations that require compatible symbol tables.


def _comp_merge_patch(fnc):
  @functools.wraps(fnc)
  def patch(arg1, arg2, *args, **kwargs):
    cdef Fst lhs
    cdef Fst rhs
    (lhs, rhs) = _compile_or_copy_two_Fsts(arg1, arg2)
    if not MergeSymbols(lhs._mfst.get(), rhs._mfst.get(),
                        MERGE_INPUT_AND_OUTPUT_SYMBOLS):
     if not FLAGS_fst_relabel_symbol_conflicts:
       raise FstSymbolTableMergeError(
           "Unable to resolve symbol table conflict without relabeling")
     else:
       raise FstOpError("Operation failed")
    return fnc(lhs, rhs, *args, **kwargs)
  return patch


equivalent = _comp_merge_patch(pywrapfst.equivalent)
randequivalent = _comp_merge_patch(pywrapfst.randequivalent)


def replace(root, *,
            call_arc_labeling=b"neither",
            return_arc_labeling=b"neither",
            bool epsilon_on_replace=False,
            int64 return_label=0,
            **replacements):
  """
  replace(root, **replacements, call_arc_labeling="neither",
          return_arc_labeling="neither", epsilon_on_replace=False,
          return_label=0)

  Constructively replaces arcs in an FST with other FST(s).

  This operation performs the dynamic replacement of arcs in one FST with
  other FSTs, allowing for the definition of FSTs analogous to RTNs. The output
  FST is the result of recursively replacing each arc in all input FSTs that
  matches some "non-terminal" with a corresponding FST. More precisely, an arc
  from state s to state d with nonterminal output label n in an input FST is
  replaced by redirecting this "call" arc to the initial state of a copy of the
  the replacement FST and then adding "return" arcs from each final state of
  the replacement FST to d in the input FST. If there are cyclic dependencies
  among the replacement rules, the resulting FST does not have a finite
  expansion and an exception will be raised.

  Args:
    root: The root FST.
    **replacements: Keyword argument label/FST pairs to be replaced in
       `root_fst`. For example, they keyword argument `DT=union("the", "a")`
       indicates that all instances of label "DT" should be replaced by the
       union of "the" and "a".
    call_arc_labeling: A string indicating which call arc labels should be
        non-epsilon. One of: "input" (default), "output", "both", "neither".
        This value is set to "neither" if epsilon_on_replace is True.
    return_arc_labeling: A string indicating which return arc labels should be
        non-epsilon. One of: "input", "output", "both", "neither" (default).
        This value is set to "neither" if epsilon_on_replace is True.
    epsilon_on_replace: Should call and return arcs be epsilon arcs? If True,
        this effectively overrides call_arc_labeling and return_arc_labeling,
        setting both to "neither".
    return_label: The integer label for return arcs.

  Returns:
    A replaced FST.

  Raises:
    KeyError: Nonterminal symbol not found.
    FstOpError: Operation failed.

  See also: `pdt_replace`.
  """
  cdef Fst root_fst = _compile_or_copy_Fst(root)
  cdef string arc_type = root_fst.arc_type()
  cdef vector[StringFstClassPair] pairs
  # This has the pleasant effect of preventing Python from garbage-collecting
  # these FSTs until we're ready.
  # TODO(kbg): Is there a better way?
  replacement_set = [(tostring(nt), _compile_or_copy_Fst(rep, arc_type)) for
                     (nt, rep) in replacements.iteritems()]
  cdef string nonterm
  cdef Fst replacement
  for (nonterm, replacement) in replacement_set:
    pairs.push_back(StringFstClassPair(nonterm, replacement._fst.get()))
  cdef ReplaceLabelType cal = _get_replace_label_type(
      tostring(call_arc_labeling), epsilon_on_replace)
  cdef ReplaceLabelType ral = _get_replace_label_type(
      tostring(return_arc_labeling), epsilon_on_replace)
  cdef unique_ptr[ReplaceOptions] opts
  opts.reset(new ReplaceOptions(-1, cal, ral, return_label))
  cdef Fst result = Fst(arc_type)
  PyniniReplace(deref(root_fst._fst), pairs, result._mfst.get(), deref(opts))
  result._check_mutating_imethod()
  return result


def union(*args):
  """
  union(*args)

  Computes the union (sum) of two or more FSTs.

  This operation computes the union (sum) of two FSTs. If A transduces string
  x to y with weight a and B transduces string w to v with weight b, then their
  union transduces x to y with weight a and w to v with weight b.

  Args:
   *args: Two or more input FSTs.

  Returns:
    An FST.
  """
  (first, *rest) = args
  if len(args) < 1:
    raise FstArgError("Expected at least 2 positional arguments "
                         "({} given)".format(len(rest) + 1))
  cdef Fst lhs = _compile_or_copy_Fst(first)
  for rhs in rest:
    lhs.union(rhs)
  return lhs


# Pushdown transducer classes and operations.


cdef class PdtParentheses(object):

  """
  PdtParentheses()

  Pushdown transducer parentheses class.

  This class wraps a vector of pairs of arc labels in which the first label is
  interpreted as a "push" stack operation and the second represents the
  corresponding "pop" operation. When efficiency is desired, the push and pop
  indices should be contiguous.

  A PDT is expressed as an (Fst, PdtParentheses) pair for the purposes of all
  supported PDT operations.
  """

  cdef vector[pair[int64, int64]] _parens

  def __repr__(self):
    return "<PdtParentheses at 0x{:x}>".format(id(self))

  def __len__(self):
    return self._parens.size()

  def __iter__(self):
    cdef size_t i = 0
    for i in xrange(self._parens.size()):
      yield (self._parens[i].first, self._parens[i].second)

  cpdef PdtParentheses copy(self):
    """
    copy(self)

    Makes a copy of this PdtParentheses object.

    Returns:
      A deep copy of the PdtParentheses object.
    """
    cpdef PdtParentheses result = PdtParentheses.__new__(PdtParentheses)
    result._parens = self._parens
    return result

  cpdef void add_pair(self, int64 push, int64 pop):
    """
    add_pair(self, push, pop)

    Adds a pair of parentheses to the set.

    Args:
      push: An arc label to be interpreted as a "push" operation.
      pop: An arc label to be interpreted as a "pop" operation.
    """
    self._parens.push_back(pair[int64, int64](push, pop))

  @classmethod
  def read(cls, filename):
    """
    PdtParentheses.read(filename)

    Reads parentheses pairs from a text file.

    This class method creates a new PdtParentheses object from a pairs of
    integer labels in a text file.

    Args:
      filename: The string location of the input file.

    Returns:
      A new PdtParentheses instance.

    Raises:
      FstIOError: Read failed.
    """
    cdef PdtParentheses result = PdtParentheses.__new__(PdtParentheses)
    if not ReadLabelPairs[int64](tostring(filename), addr(result._parens),
                                 False):
      raise FstIOError("Read failed: {!r}".format(filename))
    return result

  cpdef void write(self, filename) except *:
    """
    write(self, filename)

    Writes parentheses pairs to text file.

    This method writes the PdtParentheses object to a text file.

    Args:
      filename: The string location of the output file.

    Raises:
      FstIOError: Write failed.
    """
    if not WriteLabelPairs[int64](tostring(filename), self._parens):
      raise FstIOError("Write failed: {!r}".format(filename))


def pdt_compose(ifst1,
                ifst2,
                PdtParentheses parens,
                compose_filter=b"paren",
                bool left_pdt=True):
  """
  pdt_compose(ifst1, ifst2, parens, compose_filter="paren", left_pdt=True)

  Composes a PDT with an FST.

  This operation composes a PDT with an FST. The input PDT is defined by the
  combination of an FST and a PdtParentheses object specifying the stack
  symbols. The caller should also specify whether the left-hand or the
  right-hand FST argument is to be interpreted as a PDT.

  Args:
    ifst1: The left-hand-side input FST or PDT.
    ifst2: The right-hand-side input FST or PDT.
    parens: A PdtParentheses object specifying the input PDT's stack symbols.
    compose_filter: A string indicating the desired PDT composition filter; one
        of: "paren" (keeps parentheses), "expand" (expands and removes
        parentheses), "expand_paren" (expands and keeps parentheses).
    left_pdt: If true, the first argument is interpreted as a PDT and the
        second argument is interpreted as an FST; if false, the second
        argument is interpreted as a PDT and the first argument is interpreted
        as an FST.

  Returns:
    The FST component of an PDT produced by composition.

  Raises:
    FstOpError: Operation failed.
    FstSymbolTableMergeError: Unable to resolve symbol table conflict
        without relabeling.
  """
  cdef Fst lhs
  cdef Fst rhs
  (lhs, rhs) = _compile_or_copy_two_Fsts(ifst1, ifst2)
  _maybe_arcsort(lhs._mfst.get(), rhs._mfst.get())
  if not MergeSymbols(lhs._mfst.get(), rhs._mfst.get(),
                      MERGE_LEFT_OUTPUT_AND_RIGHT_INPUT_SYMBOLS):
    if not FLAGS_fst_relabel_symbol_conflicts:
      raise FstSymbolTableMergeError(
          "Unable to resolve symbol table conflict without relabeling")
    else:
      raise FstOpError("Operation failed")
  cdef Fst result = Fst(lhs.arc_type())
  cdef PdtComposeFilter compose_filter_enum = _get_pdt_compose_filter(
      tostring(compose_filter))
  cdef unique_ptr[PdtComposeOptions] opts
  opts.reset(new PdtComposeOptions(True, compose_filter_enum))
  PdtCompose(deref(lhs._fst), deref(rhs._fst), parens._parens,
             result._mfst.get(), deref(opts), left_pdt)
  if not result.num_states():
    logging.warning("Composed PDT has no connected states")
  result._check_mutating_imethod()
  # If the "expand" filter is selected, all parentheses have been mapped to
  # epsilon. This conveniently removes the arcs that result.
  if compose_filter_enum == EXPAND_FILTER:
    result.rmepsilon()
  # Otherwise, we need to add the parentheses to the result.
  else:
    _add_parentheses_symbols(result._mfst.get(), parens._parens, left_pdt)
  return result


def pdt_expand(ipdt,
               PdtParentheses parens,
               bool connect=True,
               bool keep_parentheses=False,
               weight=None):
  """
  pdt_expand(ipdt, parens, connect=True, keep_parentheses=False, weight=None)

  Expands a bounded-stack PDT to an FST.

  This operation converts a bounded-stack PDT into the equivalent FST. The
  input PDT is defined by the combination of an FST and a PdtParentheses object
  specifying the PDT stack symbols.

  If the input PDT does not have a bounded stack, then it is impossible to
  expand the PDT into an FST and this operation will not terminate.

  Args:
    ipdt: The FST component of the input PDT.
    parens: A PdtParentheses object specifying the input PDT's stack symbols.
    connect: Should the output FST be trimmed?
    keep_parentheses: Should the output FST preserve parentheses arcs?
    weight: A Weight or weight string indicating the desired weight threshold;
        paths with weights below this threshold will be pruned. If omitted or
        null, no paths are pruned.

  Returns:
    An FST produced by expanding the bounded-stack PDT.

  Raises:
    FstOpError: Operation failed.
  """
  cdef Fst pdt = _compile_or_copy_Fst(ipdt)
  cdef Fst result = Fst(pdt.arc_type())
  cdef WeightClass wc = _get_WeightClass_or_Zero(result.weight_type(), weight)
  cdef unique_ptr[PdtExpandOptions] opts
  opts.reset(new PdtExpandOptions(connect, keep_parentheses, wc))
  PdtExpand(deref(pdt._fst), parens._parens, result._mfst.get(), deref(opts))
  result._check_mutating_imethod()
  return result


def pdt_replace(root, *,
                pdt_parser_type=b"left",
                **replacements):
  """
  pdt_replace(root, pdt_parser_type="left", **replacements)

  Constructively replaces arcs in an FST with other FST(s), producing a PDT.

  This operation performs the dynamic replacement of arcs in one FST with
  another FST, allowing the definition of a PDT analogues to RTNs. The output
  PDT, defined by the combination of an FST and a PdtParentheses object
  specifying the PDT stack symbols, is the result of recursively replacing each
  arc in an input FST that matches some "non-terminal" with a corresponding
  FST, inserting parentheses where necessary. More precisely, an arc from
  state s to state d with nonterminal output label n in an input FST is
  replaced by redirecting this "call" arc to the initial state of a copy of the
  replacement FST and then adding "return" arcs from each final state of the
  replacement FST to d in the input FST. Unlike `replace`, this operation is
  capable of handling cyclic dependencies among replacement rules, which is
  accomplished by adding "push" stack symbols to "call" arcs and "pop" stack
  symbols to "return" arcs.

  Args:
    root: The root FST.
    pdt_parser_type: A string matching a known PdtParserType. One of: "left"
        (default), "left_sr".
    **replacements: Keyword argument label/FST pairs to be replaced in
       `root_fst`. For example, the keyword argument `DT=union("the", "a")`
       indicates that all instances of label "DT" should be replaced by the
       union of "the" and "a".

  Returns:
   An (Fst, PdtParentheses) pair defining a PDT resulting from PDT replacement.

  Raises:
    FstOpError: Operation failed.

  See also: `replace`.
  """
  cdef Fst root_fst = _compile_or_copy_Fst(root)
  cdef string arc_type = root_fst.arc_type()
  cdef vector[StringFstClassPair] pairs
  # This has the pleasant effect of preventing Python from garbage-collecting
  # these FSTs until we're ready.
  # TODO(kbg): Is there a better way?
  replacement_set = [(tostring(nt), _compile_or_copy_Fst(rep, arc_type))
                     for (nt, rep) in replacements.iteritems()]
  cdef string nonterm
  cdef Fst replacement
  for (nonterm, replacement) in replacement_set:
    pairs.push_back(StringFstClassPair(nonterm, replacement._fst.get()))
  cdef Fst result = Fst(arc_type)
  cdef PdtParentheses parens = PdtParentheses()
  PyniniPdtReplace(deref(root_fst._fst), pairs, result._mfst.get(),
                   addr(parens._parens),
                   _get_pdt_parser_type(tostring(pdt_parser_type)))
  result._check_mutating_imethod()
  return (result, parens)


def pdt_reverse(ipdt, PdtParentheses parens):
  """
  pdt_reverse(ipdt, parens)

  Reverses a PDT.

  This operation reverses an PDT. The input PDT is defined by the combination
  of an FST and a PdtParentheses object specifying the PDT stack symbols.

  Args:
    ipdt: The FST component of the input PDT.
    parens: A PdtParentheses object specifying the input PDT's stack symbols.

  Returns:
    The FST component of a PDT resulting from reversing the input PDT.
  """
  cdef Fst pdt = _compile_or_copy_Fst(ipdt)
  cdef Fst result = Fst(pdt.arc_type())
  PdtReverse(deref(pdt._fst), parens._parens, result._mfst.get())
  result._check_mutating_imethod()
  return result


def pdt_shortestpath(ipdt,
                     PdtParentheses parens,
                     queue_type=b"fifo",
                     bool keep_parentheses=False,
                     bool path_gc=True):
  """
  pdt_shortestpath(ipdt, parens, queue_type="fifo", keep_parentheses=False,
                   path_gc=True)

  Computes the shortest path through a bounded-stack PDT.

  This operation computes the shortest path through a PDT. The input PDT is
  defined by the combination of an FST and a PdtParentheses object specifying
  the PDT stack symbols.

  Args:
    ipdt: The FST component of an input PDT.
    parens: A PdtParentheses object specifying the input PDT's stack symbols.
    queue_type: A string matching a known queue type; one of: "fifo" (default),
        "lifo", "state".
    keep_parentheses: Should the output FST preserve parentheses arcs?
    path_gc: Should shortest path data be garbage-collected?

  Returns:
    A string FST representing the shortest path.

  Raises:
    FstOpError: Operation failed.
  """
  cdef Fst pdt = _compile_or_copy_Fst(ipdt)
  cdef Fst result = Fst(pdt.arc_type())
  cdef unique_ptr[PdtShortestPathOptions] opts
  opts.reset(new PdtShortestPathOptions(
        _get_queue_type(tostring(queue_type)), keep_parentheses, path_gc))
  PdtShortestPath(deref(pdt._fst), parens._parens, result._mfst.get(),
                  deref(opts))
  result._check_mutating_imethod()
  return result



# Multi-pushdown transducer classes and operations.


cdef class MPdtParentheses(object):

  """
  MPdtParentheses()

  Multi-pushdown transducer parentheses class.

  This class wraps a vector of pairs of arc labels in which the first label is
  interpreted as a "push" stack operation and the second represents the
  corresponding "pop" operation, and an equally sized vector which assigns each
  pair to a stack. The library currently only permits two stacks (numbered 1
  and 2) to be used.

  A MPDT is expressed as an (Fst, MPdtParentheses) pair for the purposes of all
  supported MPDT operations.
  """

  cdef vector[pair[int64, int64]] _parens
  cdef vector[int64] _assign

  def __repr__(self):
    return "<MPdtParentheses at 0x{:x}>".format(id(self))

  def __len__(self):
    return self._parens.size()

  def __iter__(self):
    cdef size_t i = 0
    for i in xrange(self._parens.size()):
      yield (self._parens[i].first, self._parens[i].second, self._assign[i])

  cpdef MPdtParentheses copy(self):
    """
    copy(self)

    Makes a copy of this MPdtParentheses object.

    Returns:
      A deep copy of the MPdtParentheses object.
    """
    cpdef MPdtParentheses result = MPdtParentheses.__new__(MPdtParentheses)
    result._parens = self._parens
    result._assign = self._assign
    return result

  cpdef void add_triple(self, int64 push, int64 pop, int64 assignment):
    """
    add_triple(self, push, pop, assignment)

    Adds a triple of (left parenthesis, right parenthesis, stack assignment)
    triples to the object.

    Args:
      push: An arc label to be interpreted as a "push" operation.
      pop: An arc label to be interpreted as a "pop" operation.
      assignment: An arc label indicating what stack the parentheses pair is
          assigned to.
    """
    self._parens.push_back(pair[int64, int64](push, pop))
    self._assign.push_back(assignment)

  @classmethod
  def read(cls, filename):
    """
    MPdtParentheses.read(filename)

    Reads parentheses/assignment triples from a text file.

    This class method creates a new MPdtParentheses object from a pairs of
    integer labels in a text file.

    Args:
      filename: The string location of the input file.

    Returns:
      A new MPdtParentheses instance.

    Raises:
      FstIOError: Read failed.
    """
    cdef MPdtParentheses result = MPdtParentheses.__new__(MPdtParentheses)
    if not ReadLabelTriples[int64](tostring(filename), addr(result._parens),
                                   addr(result._assign), False):
      raise FstIOError("Read failed: {!r}".format(filename))
    return result

  cpdef void write(self, filename) except *:
    """
    write(self, filename)

    Writes parentheses triples to a text file.

    This method writes the MPdtParentheses object to a text file.

    Args:
      filename: The string location of the output file.

    Raises:
      FstIOError: Write failed.
    """
    if not WriteLabelTriples[int64](tostring(filename), self._parens,
                                    self._assign):
      raise FstIOError("Write failed: {!r}".format(filename))


cpdef Fst mpdt_compose(ifst1, ifst2, MPdtParentheses parens,
                       compose_filter=b"paren", bool left_mpdt=True):
  """
  mpdt_compose(ifst1, ifst2, parens, compose_filter="paren", left_mpdt=True)

  Composes a MPDT with an FST.

  This operation composes a MPDT with an FST. The input MPDT is defined by the
  combination of an FST and a MPdtParentheses object specifying the stack
  symbols and assignments. The caller should also specify whether the left-hand
  or the right-hand FST argument is to be interpreted as a MPDT.

  Args:
    ifst1: The left-hand-side input FST or MPDT.
    ifst2: The right-hand-side input FST or MPDT.
    parens: A MPdtParentheses object specifying the input MPDT's stack
        operations and assignments.
    compose_filter: A string indicating the desired MPDT composition filter; one
        of: "paren" (keeps parentheses), "expand" (expands and removes
        parentheses), "expand_paren" (expands and keeps parentheses).
    left_mpdt: If true, the first argument is interpreted as a MPDT and the
        second argument is interpreted as an FST; if false, the second
        argument is interpreted as a MPDT and the first argument is interpreted
        as an FST.

  Returns:
    The FST component of an MPDT produced by composition.

  Raises:
    FstOpError: Operation failed.
    FstSymbolTableMergeError: Unable to resolve symbol table conflict
        without relabeling.

  See also: `compose`.
  """
  cdef Fst lhs
  cdef Fst rhs
  (lhs, rhs) = _compile_or_copy_two_Fsts(ifst1, ifst2)
  _maybe_arcsort(lhs._mfst.get(), rhs._mfst.get())
  if not MergeSymbols(lhs._mfst.get(), rhs._mfst.get(),
                      MERGE_LEFT_OUTPUT_AND_RIGHT_INPUT_SYMBOLS):
    if not FLAGS_fst_relabel_symbol_conflicts:
      raise FstSymbolTableMergeError(
          "Unable to resolve symbol table conflict without relabeling")
    else:
      raise FstOpError("Operation failed")
  cdef Fst result = Fst(lhs.arc_type())
  cdef PdtComposeFilter compose_filter_enum = _get_pdt_compose_filter(
      tostring(compose_filter))
  cdef unique_ptr[MPdtComposeOptions] opts
  opts.reset(new MPdtComposeOptions(True, compose_filter_enum))
  MPdtCompose(deref(lhs._fst), deref(rhs._fst), parens._parens,
              parens._assign, result._mfst.get(), deref(opts), left_mpdt)
  if not result.num_states():
    logging.warning("Composed MPDT has no connected states")
  if result._fst.get().Properties(kError, True) == kError:
    raise FstOpError("Operation failed")
  # If the "expand" filter is selected, all parentheses have been mapped to
  # epsilon. This conveniently removes the arcs that result.
  if compose_filter_enum == EXPAND_FILTER:
    result.rmepsilon()
  # Otherwise, we need to add the parentheses to the result.
  else:
    _add_parentheses_symbols(result._mfst.get(), parens._parens, left_mpdt)
  return result


def mpdt_expand(impdt, MPdtParentheses parens, bool connect=True,
                bool keep_parentheses=False):
  """
  mpdt_expand(impdt, parens, connect=True, keep_parentheses=False):

  Expands a bounded-stack MPDT to an FST.

  This operation converts a bounded-stack MPDT into the equivalent FST. The
  input MPDT is defined by the combination of an FST and a MPdtParentheses
  object specifying the MPDT stack symbols and assignments.

  If the input MPDT does not have a bounded stack, then it is impossible to
  expand the MPDT into an FST and this operation will not terminate.

  Args:
    impdt: The FST component of the input MPDT.
    parens: A MPdtParentheses object specifying the input PDT's stack
        symbols and assignments.
    connect: Should the output FST be trimmed?
    keep_parentheses: Should the output FST preserve parentheses arcs?

  Returns:
    An FST produced by expanding the bounded-stack MPDT.

  Raises:
    FstOpError: Operation failed.
  """
  cdef Fst mpdt = _compile_or_copy_Fst(impdt)
  cdef Fst result = Fst(mpdt.arc_type())
  cdef unique_ptr[MPdtExpandOptions] opts
  opts.reset(new MPdtExpandOptions(connect, keep_parentheses))
  MPdtExpand(deref(mpdt._fst), parens._parens, parens._assign,
             result._mfst.get(), deref(opts))
  result._check_mutating_imethod()
  return result


def mpdt_reverse(impdt, MPdtParentheses parens):
  """
  mpdt_reverse(impdt, parens)

  Reverses a MPDT.

  This operation reverses an MPDT. The input MPDT is defined by the combination
  of an FST and a MPdtParentheses object specifying the MPDT stack symbols
  and assignments. Unlike PDT reversal, which only modifies the FST component,
  this operation also reverses the stack assignments. assignments.

  Args:
    impdt: The FST component of the input MPDT.
    parens: A MPdtParentheses object specifying the input MPDT's stack symbols
        and assignments.

  Returns:
    A (Fst, MPdtParentheses) pair specifying the reversed MPDT.
  """
  cdef Fst mpdt = _compile_or_copy_Fst(impdt)
  cdef Fst result_fst = Fst(mpdt.arc_type())
  cdef MPdtParentheses result_parens = parens.copy()
  MPdtReverse(deref(mpdt._fst), result_parens._parens,
              addr(result_parens._assign), result_fst._mfst.get())
  result_fst._check_mutating_imethod()
  return (result_fst, result_parens)


# Class for printing paths.


cdef class StringPaths(object):

  """
  StringPaths(fst, token_type="byte", isymbols=None, osymbols=None)

  Iterator for string paths in acyclic FST.

  This class provides an iterator over all paths (represented as pairs of
  strings and an associated path weight) through an acyclic FST. This
  operation is only feasible when the FST is acyclic. Depending on the
  requested token type, the arc labels along the input and output sides of a
  path are interpreted as UTF-8-encoded Unicode strings, raw bytes, or a
  concatenation of string labels from a symbol table. This class is normally
  created by invoking the `paths` method of `Fst`.

  Args:
    input_token_type: A string indicating how the input strings are to be
        constructed from arc labels---one of: "byte" (interprets arc labels
        as raw bytes), "utf8" (interprets arc labels as Unicode code points),
        or a SymbolTable.
    output_token_type: A string indicating how the output strings are to be
        constructed from arc labels---one of: "byte" (interprets arc labels
        as raw bytes), "utf8" (interprets arc labels as Unicode code points),
        or a SymbolTable.
    rm_epsilon: Should epsilons be removed?

  Raises:
    FstArgError: Unknown token type.
    FstArgError: FST is not acyclic.
  """

  cdef unique_ptr[StringPathsClass] _paths

  def __repr__(self):
    return "<StringPaths at 0x{:x}>".format(id(self))

  def __init__(self, ifst, input_token_type=b"byte",
               output_token_type=b"byte", bool rm_epsilon=True):
    # Sorts out the token type arguments.
    cdef StringTokenType itype
    cdef SymbolTable_ptr isyms = NULL
    if isinstance(input_token_type, pywrapfst._SymbolTable):
      itype = SYMBOL
      isyms = (<SymbolTable_ptr> (<_SymbolTable> input_token_type)._table)
    else:
      itype = _get_token_type(tostring(input_token_type))
    cdef StringTokenType otype
    cdef SymbolTable_ptr osyms = NULL
    if isinstance(output_token_type, pywrapfst._SymbolTable):
      otype = SYMBOL
      osyms = (<SymbolTable_ptr> (<_SymbolTable> output_token_type)._table)
    else:
      otype = _get_token_type(tostring(output_token_type))
    cdef Fst ifst_compiled = _compile_or_copy_Fst(ifst)
    self._paths.reset(new StringPathsClass(deref(ifst_compiled._fst), itype,
                                           otype, isyms, osyms, rm_epsilon))
    if self._paths.get().Error():
      raise FstArgError("FST is not acyclic")

  # This just registers this class as a possible iterator.
  def __iter__(self):
    return self

  # Magic method used to get a Pythonic API out of the C++ API.
  def __next__(self):
    if self.done():
      raise StopIteration
    result = (self.istring(), self.ostring(), self.weight())
    self.next()
    return result

  cpdef bool done(self):
    """
    done(self)

    Indicates whether the iterator is exhausted or not.

    Returns:
      True if the iterator is exhausted, False otherwise.
    """
    return self._paths.get().Done()

  cpdef void next(self):
    """
    next(self)

    Advances the iterator.
    """
    self._paths.get().Next()

  cpdef void reset(self):
    """
    reset(self)

    Resets the iterator to the initial position.
    """
    self._paths.get().Reset()


  cpdef bool error(self):
    """
    error(self)

    Indicates whether the StringPaths has encountered an error.

    Returns:
      True if the StringPaths is in an errorful state, False otherwise.
    """
    return self._paths.get().Error()

  cpdef string istring(self):
    """
    istring(self)

    Returns the current path's input string.

    Returns:
      The path's input string.
    """
    return self._paths.get().IString()

  def iter_istrings(self):
    """
    iter_istrings(self)

    Generates all input strings in the FST.

    This method returns a generator over all input strings in the path. The
    caller is responsible for resetting the iterator if desired.

    Yields:
      All input strings.
    """
    while not self._paths.get().Done():
      yield self.istring()
      self._paths.get().Next()

  cpdef string ostring(self):
    """
    ostring(self)

    Returns the current path's output string.

    Returns:
      The path's output string.
    """
    return self._paths.get().OString()

  def iter_ostrings(self):
    """
    iter_ostrings(self)

    Generates all output strings in the FST.

    This method returns a generator over all output strings in the path. The
    caller is responsible for resetting the iterator if desired.

    Yields:
      All output strings.
    """
    while not self._paths.get().Done():
      yield self.ostring()
      self._paths.get().Next()

  cpdef _Weight weight(self):
    """
    weight(self)

    Returns the current path's total weight.

    Returns:
      The path's Weight.
    """
    cdef _Weight weight = _Weight.__new__(_Weight)
    weight._weight.reset(new WeightClass(self._paths.get().Weight()))
    return weight

  def iter_weights(self):
    """
    iter_weights(self)

    Generates all path weights in the FST.

    This method returns a generator over all path weights. The caller is
    responsible for resetting the iterator if desired.

    Yields:
      All weights.
    """
    while not self._paths.get().Done():
      yield self.weight()
      self._paths.get().Next()

  def ilabels(self):
    """
    ilabels(self)

    Returns the input labels for the current path.

    Returns:
      A list of input labels for the current path.
    """
    return list(self._paths.get().ILabels())

  def olabels(self):
    """
    olabels(self)

    Returns the output labels for the current path.

    Returns:
      A list of output labels for the current path.
    """
    return list(self._paths.get().OLabels())


# Class for FAR reading and/or writing.


cdef class Far(object):

  """
  Far(filename, mode="r", arc_type="standard", far_type="default")

  Pynini FAR ("Fst ARchive") object.

  This class is used to either read FSTs from or write FSTs to a FAR. When
  opening a FAR for writing, the user may also specify the desired arc type
  and FAR type.

  Args:
    filename: A string indicating the filename.
    mode: FAR IO mode; one of: "r" (open for reading), "w" (open for writing).
    arc_type: Desired arc type; this is ignored if the FAR is opened for
        reading.
    far_type: Desired FAR type; this is ignored if the FAR is opened for
        reading.
  """

  cdef char _mode
  cdef string _name
  cdef FarReader _reader
  cdef FarWriter _writer

  # Instances holds either a FarReader or a FarWriter, a boolean indicating

  def __init__(self, filename, mode=b"r", arc_type=b"standard",
               far_type=b"default"):
    self._name = tostring(filename)
    self._mode = tostring(mode)[0]
    if self._mode == b"r":
      self._reader = FarReader.open(self._name)
    elif self._mode == b"w":
      self._writer = FarWriter.create(self._name, arc_type=arc_type,
                                      far_type=far_type)
    else:
      raise FstArgError("Unknown mode: {!r}".format(mode))

  def __repr__(self):
    return "<{} Far {!r}, mode '{:c}' at 0x{:x}>".format(self.far_type(),
                                                         self._name,
                                                         self._mode,
                                                         id(self))

  cdef void _check_mode(self, char mode) except *:
    if not self._mode == mode:
      raise FstOpError("Cannot invoke method in current mode: '{:c}'".format(
                       self._mode))

  cdef void _check_not_mode(self, char mode) except *:
    if self._mode == mode:
      raise FstOpError("Cannot invoke method in current mode: '{:c}'".format(
                       self._mode))

  # API shared between FarReader and FarWriter.

  cpdef bool error(self) except *:
    """
    error(self)

    Indicates whether the FAR has encountered an error.

    Returns:
      True if the FAR is in an errorful state, False otherwise.
    """
    if self._mode == b"r":
      return self._reader.error()
    elif self._mode == b"w":
      return self._writer.error()
    else:
      return False

  cpdef string arc_type(self):
    """
    arc_type(self)

    Returns a string indicating the arc type.
    """
    self._check_not_mode(b"c")
    return (self._reader._arc_type() if self._mode == b"r" else
            self._writer._arc_type())

  cpdef bool closed(self):
    """
    closed(self)

    Indicates whether the FAR is closed for IO.
    """
    return self._mode == b"c"

  cpdef string far_type(self):
    """far_type(self)

    Returns a string indicating the FAR type.
    """
    if self._mode == b"r":
      return self._reader.far_type()
    elif self._mode == b"w":
      return self._writer.far_type()
    else:
      return b"closed"

  cpdef string mode(self):
    """
    mode(self)

    Returns a char indicating the FAR's current mode.
    """
    return "{:c}".format(self._mode)

  cpdef string name(self):
    """
    name(self)

    Returns the FAR's filename.
    """
    return self._name

  # FarReader API.

  # This just registers this class as a possible iterator.
  def __iter__(self):
    return self

  def __next__(self):
    self._check_mode(b"r")
    (key, mfst) = next(self._reader)
    return (key, _init_Fst_from_MutableFst(mfst))

  cpdef bool done(self) except *:
    """
    done(self)

    Indicates whether the iterator is exhausted or not.

    Returns:
      True if the iterator is exhausted, False otherwise.

    Raises:
      FstOpError: Cannot invoke method in current mode.
    """
    self._check_mode(b"r")
    self._reader.done()

  cpdef bool find(self, key) except *:
    """
    find(self, key)

    Sets the current position to the first entry greater than or equal to the
    key (a string) and indicates whether or not a match was found.

    Args:
      key: A string key.

    Returns:
      True if the key was found, False otherwise.

    Raises:
      FstOpError: Cannot invoke method in current mode.
    """
    self._check_mode(b"r")
    return self._reader.find(key)

  def get_fst(self):
    """
    get_fst(self)

    Returns the FST at the current position.

    Returns:
      A copy of the FST at the current position.

    Raises:
      FstOpError: Cannot invoke method in current mode.
    """
    self._check_mode(b"r")
    return _init_Fst_from_MutableFst(self._reader.get_fst())

  cpdef string get_key(self) except *:
    """
    get_key(self)

    Returns the string key at the current position.

    Returns:
      The string key at the current position.

    Raises:
      FstOpError: Cannot invoke method in current mode.
    """
    self._check_mode(b"r")
    return self._reader.get_key()

  cpdef void next(self) except *:
    """
    next(self)

    Advances the iterator.

    Raises:
      FstOpError: Cannot invoke method in current mode.
    """
    self._check_mode(b"r")
    self._reader.next()

  cpdef void reset(self) except *:
    """
    reset(self)

    Resets the iterator to the initial position.

    Raises:
      FstOpError: Cannot invoke method in current mode.
    """
    self._check_mode(b"r")
    self._reader.reset()

  def __getitem__(self, key):
    if not self.find(key):
      raise KeyError(key)
    return self.get_fst()

  # FarWriter API.

  cpdef void add(self, key, Fst fst):
    """
    add(self, key, fst)

    Adds an FST to the FAR (when open for writing).

    This methods adds an FST to the FAR which can be retrieved with the
    specified string key.

    Args:
      key: The string used to key the input FST.
      fst: The FST to write to the FAR.

    Raises:
      FstOpError: Cannot invoke method in current mode.
      FstOpError: Incompatible or invalid arc type.
    """
    self._check_mode(b"w")
    self._writer.add(key, fst)

  def __setitem__(self, key, Fst fst):
    self._check_mode(b"w")
    self._writer[key] = fst

  cpdef void close(self):
    """
    close(self)

    Closes the FAR and flushes to disk (when open for writing).

    Raises:
      FstOpError: Cannot invoke method in current mode.
    """
    self._check_mode(b"w")
    self._writer._close()
    self._mode = b"c"

  # Adds support for use as a PEP-343 context manager.

  def __enter__(self):
    return self

  def __exit__(self, exc, value, tb):
    if self._mode == b"w":
      self._writer._close()
      self._mode = b"c"


## PYTHON IMPORTS.


# Classes from pywrapfst.


from pywrapfst import Arc
from pywrapfst import ArcIterator
from pywrapfst import EncodeMapper
from pywrapfst import MutableArcIterator
from pywrapfst import StateIterator
from pywrapfst import SymbolTable
from pywrapfst import SymbolTableIterator
from pywrapfst import Weight


# Exceptions not yet imported.


from pywrapfst import FstBadWeightError
from pywrapfst import \
    FstDeletedConstructorError
from pywrapfst import FstIndexError


# FST properties.


from pywrapfst import EXPANDED
from pywrapfst import MUTABLE
from pywrapfst import ERROR
from pywrapfst import ACCEPTOR
from pywrapfst import NOT_ACCEPTOR
from pywrapfst import I_DETERMINISTIC
from pywrapfst import NON_I_DETERMINISTIC
from pywrapfst import O_DETERMINISTIC
from pywrapfst import NON_O_DETERMINISTIC
from pywrapfst import EPSILONS
from pywrapfst import NO_EPSILONS
from pywrapfst import I_EPSILONS
from pywrapfst import NO_I_EPSILONS
from pywrapfst import O_EPSILONS
from pywrapfst import NO_O_EPSILONS
from pywrapfst import I_LABEL_SORTED
from pywrapfst import NOT_I_LABEL_SORTED
from pywrapfst import O_LABEL_SORTED
from pywrapfst import NOT_O_LABEL_SORTED
from pywrapfst import WEIGHTED
from pywrapfst import UNWEIGHTED
from pywrapfst import CYCLIC
from pywrapfst import ACYCLIC
from pywrapfst import INITIAL_CYCLIC
from pywrapfst import INITIAL_ACYCLIC
from pywrapfst import TOP_SORTED
from pywrapfst import NOT_TOP_SORTED
from pywrapfst import ACCESSIBLE
from pywrapfst import NOT_ACCESSIBLE
from pywrapfst import COACCESSIBLE
from pywrapfst import NOT_COACCESSIBLE
from pywrapfst import STRING
from pywrapfst import NOT_STRING
from pywrapfst import WEIGHTED_CYCLES
from pywrapfst import UNWEIGHTED_CYCLES
from pywrapfst import NULL_PROPERTIES
from pywrapfst import COPY_PROPERTIES
from pywrapfst import INTRINSIC_PROPERTIES
from pywrapfst import EXTRINSIC_PROPERTIES
from pywrapfst import SET_START_PROPERTIES
from pywrapfst import SET_FINAL_PROPERTIES
from pywrapfst import ADD_STATE_PROPERTIES
from pywrapfst import ADD_ARC_PROPERTIES
from pywrapfst import SET_ARC_PROPERTIES
from pywrapfst import DELETE_STATE_PROPERTIES
from pywrapfst import DELETE_ARC_PROPERTIES
from pywrapfst import STATE_SORT_PROPERTIES
from pywrapfst import ARC_SORT_PROPERTIES
from pywrapfst import \
    I_LABEL_INVARIANT_PROPERTIES
from pywrapfst import \
    O_LABEL_INVARIANT_PROPERTIES
from pywrapfst import \
    WEIGHT_INVARIANT_PROPERTIES
from pywrapfst import \
    ADD_SUPERFINAL_PROPERTIES
from pywrapfst import \
    RM_SUPERFINAL_PROPERTIES
from pywrapfst import BINARY_PROPERTIES
from pywrapfst import TRINARY_PROPERTIES
from pywrapfst import POS_TRINARY_PROPERTIES
from pywrapfst import NEG_TRINARY_PROPERTIES
from pywrapfst import FST_PROPERTIES


# Arc iterator properties.


from pywrapfst import ARC_I_LABEL_VALUE
from pywrapfst import ARC_O_LABEL_VALUE
from pywrapfst import ARC_WEIGHT_VALUE
from pywrapfst import ARC_NEXT_STATE_VALUE
from pywrapfst import ARC_NO_CACHE
from pywrapfst import ARC_VALUE_FLAGS
from pywrapfst import ARC_FLAGS


# Encode mapper properties.


from pywrapfst import ENCODE_LABELS
from pywrapfst import ENCODE_WEIGHTS
from pywrapfst import ENCODE_FLAGS


# Single-char aliases for the biggest three functions.


a = acceptor
t = transducer
u = union


# The following wrapper converts destructive FST operations (defined as
# instance methods on the Fst class) to module-level functions which make a
# copy of the input FST and then apply the destructive operation.


def _copy_patch(fnc):
  # The junk in the `functools.wraps` decorator is due to a long-standing bug
  # in Python 2.7 (https://bugs.python.org/issue3445).
  @functools.wraps(fnc, ("__name__", "__doc__"))
  def patch(arg1, *args, **kwargs):
    cdef Fst result = _compile_or_copy_Fst(arg1)
    fnc(result, *args, **kwargs)
    return result
  return patch


arcsort = _copy_patch(Fst.arcsort)
closure = _copy_patch(Fst.closure)
concat = _copy_patch(Fst.concat)
connect = _copy_patch(Fst.connect)
decode = _copy_patch(Fst.decode)
encode = _copy_patch(Fst.encode)
invert = _copy_patch(Fst.invert)
minimize = _copy_patch(Fst.minimize)
optimize = _copy_patch(Fst.optimize)
project = _copy_patch(Fst.project)
relabel_pairs = _copy_patch(Fst.relabel_pairs)
relabel_tables = _copy_patch(Fst.relabel_tables)
reweight = _copy_patch(Fst.reweight)
topsort = _copy_patch(Fst.topsort)


# Weight operations.

from pywrapfst import plus
from pywrapfst import times
from pywrapfst import divide
from pywrapfst import power

