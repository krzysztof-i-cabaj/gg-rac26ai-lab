# ==============================================================================
# Tytul:        T06_critical_process.ps1
# Opis:         Definicja testu T6 (Process marked as critical) dla tests/run_test.ps1; opis w TESTS.md / TESTS_PL.md.
# Description [EN]: Definition of test T6 (Process marked as critical) for tests/run_test.ps1; see TESTS.md.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.1 (Expected: oczekiwanie A4 / A4 expectation)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - czyta ja tests/run_test.ps1
# Requirements [EN]: - read by tests/run_test.ps1
#
# Uzycie [PL]:       .\tests\run_test.ps1 -Test T6
# Usage [EN]:        .\tests\run_test.ps1 -Test T6
# ==============================================================================
@{
    Id          = 'T6'
    Title       = 'Process marked as critical'
    Kind        = 'kill-ext'          # relocate, poweroff, abort, kill-sm, kill-ext, link-down, none
    Target      = 'ggrac1'
    Destructive = $true      # TESTS.md: may leave the lab broken
    Back        = $true      # needs a measured <test>-back run to the base state
    PreSec      = 60             # load before the fault
    PostSec     = 180            # observation after t_lag_ok
    TimeoutSec  = 900            # give up waiting for recovery
    Notes       = 'Manual step before: Critical to deployment health ON for EXT1 (Web UI); export the profile before and after.'
    # A4 (video): written to expected.json and summary.json before the fault; 'nie wiemy' = no guess
    Expected    = @{
        Hypothesis = 'a failure of a process marked as critical can interfere with XAG restarting the deployment (docs say can interfere, not blocks)'
        Source     = 'MAA 26ai'
        FinalNode  = 'nie wiemy'      # GoldenGate node at the end
        Recovers   = 'nie wiemy'       # recovers without a human
        RtoS       = 'nie wiemy'      # number = upper bound in seconds
        DataLoss   = 0         # rows lost
    }
}
