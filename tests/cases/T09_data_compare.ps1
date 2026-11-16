# ==============================================================================
# Tytul:        T09_data_compare.ps1
# Opis:         Definicja testu T9 (Data comparison) dla tests/run_test.ps1; opis w TESTS.md / TESTS_PL.md.
# Description [EN]: Definition of test T9 (Data comparison) for tests/run_test.ps1; see TESTS.md.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.1 (Expected: oczekiwanie A4 / A4 expectation)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - czyta ja tests/run_test.ps1
# Requirements [EN]: - read by tests/run_test.ps1
#
# Uzycie [PL]:       .\tests\run_test.ps1 -Test T9
# Usage [EN]:        .\tests\run_test.ps1 -Test T9
# ==============================================================================
@{
    Id          = 'T9'
    Title       = 'Data comparison'
    Kind        = 'none'          # relocate, poweroff, abort, kill-sm, kill-ext, link-down, none
    Target      = ''
    Destructive = $false      # TESTS.md: may leave the lab broken
    Back        = $false      # needs a measured <test>-back run to the base state
    PreSec      = 0             # load before the fault
    PostSec     = 30            # observation after t_lag_ok
    TimeoutSec  = 300            # give up waiting for recovery
    Notes       = 'Runs after every test; here on its own.'
    # A4 (video): written to expected.json and summary.json before the fault; 'nie wiemy' = no guess
    Expected    = @{
        Hypothesis = 'equal counts and sums, no missing and no duplicate SEQ'
        Source     = 'lab verification report'
        FinalNode  = 'ggrac1'      # GoldenGate node at the end
        Recovers   = 'nie dotyczy'       # recovers without a human
        RtoS       = 'nie dotyczy'      # number = upper bound in seconds
        DataLoss   = 0         # rows lost
    }
}
