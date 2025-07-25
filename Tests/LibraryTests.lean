import Tests.TestFramework
import LeanSerial
import Std.Data.HashMap
import Std.Data.HashSet
import Lean.Data.Json
import Lean.Data.Position
import Lean.Data.RBMap
import Lean.Data.PersistentHashMap

open TestFramework

namespace LibraryTests

def test_hashmap_impl : IO TestResult := do
  let hm1 := Std.HashMap.ofList [(1, "one"), (2, "two"), (3, "three")]
  let bytes: ByteArray := LeanSerial.serialize hm1
  match (LeanSerial.deserialize bytes : Except String (Std.HashMap Nat String)) with
  | .error e => return TestResult.failure "HashMap" s!"Failed to deserialize: {e}"
  | .ok hm2 =>
    let list1 := hm1.toList.toArray.qsort (fun a b => a.1 < b.1)
    let list2 := hm2.toList.toArray.qsort (fun a b => a.1 < b.1)
    if list1.size == list2.size &&
       (List.range list1.size).all (fun i => list1[i]! == list2[i]!) then
      return TestResult.success "HashMap"
    else
      return TestResult.failure "HashMap" "Value mismatch"

def test_hashmap : IO Unit := do
  let result ← test_hashmap_impl
  if result.passed then
    IO.println "  ✓ HashMap"
  else
    IO.println s!"  ✗ HashMap: {result.error.getD "Unknown error"}"

def test_hashset_impl : IO TestResult := do
  let hs1 := Std.HashSet.ofList [1, 2, 3]
  let bytes: ByteArray := LeanSerial.serialize hs1
  match (LeanSerial.deserialize bytes : Except String (Std.HashSet Nat)) with
  | .error e => return TestResult.failure "HashSet" s!"Failed to deserialize: {e}"
  | .ok hs2 =>
    let list1 := hs1.toList.toArray.qsort (· < ·)
    let list2 := hs2.toList.toArray.qsort (· < ·)
    if list1.size == list2.size &&
       (List.range list1.size).all (fun i => list1[i]! == list2[i]!) then
      return TestResult.success "HashSet"
    else
      return TestResult.failure "HashSet" "Value mismatch"

def test_hashset : IO Unit := do
  let result ← test_hashset_impl
  if result.passed then
    IO.println "  ✓ HashSet"
  else
    IO.println s!"  ✗ HashSet: {result.error.getD "Unknown error"}"

def test_rbmap_impl : IO TestResult := do
  let rb1 : Lean.RBMap Nat String compare :=
    Lean.RBMap.empty.insert 1 "one" |>.insert 2 "two" |>.insert 3 "three"
  let bytes: ByteArray := LeanSerial.serialize rb1
  match (LeanSerial.deserialize bytes : Except String (Lean.RBMap Nat String compare)) with
  | .error e => return TestResult.failure "RBMap" s!"Failed to deserialize: {e}"
  | .ok rb2 =>
    let list1 := rb1.toList.toArray.qsort (fun a b => a.1 < b.1)
    let list2 := rb2.toList.toArray.qsort (fun a b => a.1 < b.1)
    if list1.size == list2.size &&
       (List.range list1.size).all (fun i => list1[i]! == list2[i]!) then
      return TestResult.success "RBMap"
    else
      return TestResult.failure "RBMap" "Value mismatch"

def test_rbmap : IO Unit := do
  let result ← test_rbmap_impl
  if result.passed then
    IO.println "  ✓ RBMap"
  else
    IO.println s!"  ✗ RBMap: {result.error.getD "Unknown error"}"

-- PersistentHashMap
def test_persistent_hashmap_impl : IO TestResult := do
  let phm1 := Lean.PersistentHashMap.empty.insert 1 "one" |>.insert 2 "two" |>.insert 3 "three"
  let bytes: ByteArray := LeanSerial.serialize phm1
  match (LeanSerial.deserialize bytes : Except String (Lean.PersistentHashMap Nat String)) with
  | .error e => return TestResult.failure "PersistentHashMap" s!"Failed to deserialize: {e}"
  | .ok phm2 =>
    let list1 := phm1.toList.toArray.qsort (fun a b => a.1 < b.1)
    let list2 := phm2.toList.toArray.qsort (fun a b => a.1 < b.1)
    if list1.size == list2.size &&
       (List.range list1.size).all (fun i => list1[i]! == list2[i]!) then
      return TestResult.success "PersistentHashMap"
    else
      return TestResult.failure "PersistentHashMap" "Value mismatch"

def test_persistent_hashmap : IO Unit := do
  let result ← test_persistent_hashmap_impl
  if result.passed then
    IO.println "  ✓ PersistentHashMap"
  else
    IO.println s!"  ✗ PersistentHashMap: {result.error.getD "Unknown error"}"

def run: IO Bool := do
  let results ← [
    runTests "Standard Library Types" [
      test_roundtrip "JSON Object" (Lean.Json.mkObj [("key", Lean.Json.str "value")]),
      test_roundtrip "JSON Complex" (Lean.Json.arr #[Lean.Json.str "value1", Lean.Json.str "value2", Lean.Json.num 42, Lean.Json.bool true, Lean.Json.null]),
      test_roundtrip "Position" (Lean.Position.mk 1 2)
    ],

    runTests "HashMap/HashSet" [
      test_hashmap_impl,
      test_hashset_impl
    ],

    runTests "Red-Black Trees" [
      test_rbmap_impl
    ],

    runTests "Persistent Collections" [
      test_persistent_hashmap_impl
    ]
  ].mapM id

  return results.all (· == true)

end LibraryTests
