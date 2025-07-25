import Tests.PrimitiveTests
import Tests.TimeTests
import Tests.ContainerTests
import Tests.StructureTests
import Tests.LibraryTests
import Tests.MetaTests

open LeanSerial

def runTestSuite (suiteName : String) (tests : IO Bool) : IO Bool := do
  IO.println ""
  IO.println s!"═══ Running {suiteName} ═══"
  try
    let success ← tests
    if success then
      IO.println s!"✓ {suiteName} completed"
    else
      IO.println s!"✗ {suiteName} failed"
    return success
  catch e =>
    IO.println s!"✗ {suiteName} failed: {e}"
    return false

def main : IO Unit := do
  IO.println "LeanSerial Test Suite"
  IO.println "====================="

  let results ← [
    runTestSuite "Primitive Types" PrimitiveTests.run,
    runTestSuite "Time Types" TimeTests.run,
    runTestSuite "Container Types" ContainerTests.run,
    runTestSuite "Structures" StructureTests.run,
    runTestSuite "Inductive Structures" InductiveTests.run,
    runTestSuite "Polymorphic Structures" PolymorphicTests.run,
    runTestSuite "Library Types" LibraryTests.run,
    runTestSuite "Meta Types" MetaTests.run,
    runTestSuite "Refs Format" RefsTests.run
  ].mapM id

  let totalTests := results.length
  let passedTests := results.filter (· == true) |>.length
  let failedTests := totalTests - passedTests

  IO.println ""
  IO.println "═══ Test Summary ═══"
  IO.println s!"Total test suites: {totalTests}"
  IO.println s!"Passed: {passedTests}"
  IO.println s!"Failed: {failedTests}"

  if failedTests > 0 then
    IO.Process.exit 1
  else
    IO.println "All tests passed! ✓"
