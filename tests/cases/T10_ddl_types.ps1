# ==============================================================================
# Tytul:        T10_ddl_types.ps1
# Opis:         Definicja testu T10 (DDL and 26ai data types) dla tests/run_test.ps1; opis w TESTS.md / TESTS_PL.md.
# Description [EN]: Definition of test T10 (DDL and 26ai data types) for tests/run_test.ps1; see TESTS.md.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.2 (Steps = ddl-types: kroki DDL w automacie testow / DDL steps in the test automation); 1.1 (Expected: oczekiwanie A4)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - czyta ja tests/run_test.ps1
# Requirements [EN]: - read by tests/run_test.ps1
#
# Uzycie [PL]:       .\tests\run_test.ps1 -Test T10
# Usage [EN]:        .\tests\run_test.ps1 -Test T10
# ==============================================================================
@{
    Id          = 'T10'
    Title       = 'DDL and 26ai data types'
    Kind        = 'none'          # relocate, poweroff, abort, kill-sm, kill-ext, link-down, none
    Target      = ''
    Destructive = $false      # TESTS.md: may leave the lab broken
    Back        = $false      # needs a measured <test>-back run to the base state
    PreSec      = 0             # load before the fault
    PostSec     = 120            # observation after t_lag_ok
    TimeoutSec  = 600            # give up waiting for recovery
    # DDL steps run by the test automation at the start of the observation (guest/shared/t10_ddl_steps.sh);
    # pass needs every step on the target and equal rows, no steps = measurement_error ddl_not_run
    Steps       = 'ddl-types'
    Notes       = 'DDL steps of TESTS.md T10 run by the test automation (t10_steps.log).'
    # A4 (video): written to expected.json and summary.json before the fault; 'nie wiemy' = no guess
    Expected    = @{
        Hypothesis = 'rows and DDL replicated, values equal on both sides (VECTOR, BOOLEAN, JSON)'
        Source     = 'GG 26ai Release Notes (types since 23.4); DDL INCLUDE MAPPED unchecked in Reference 26ai'
        FinalNode  = 'ggrac1'      # GoldenGate node at the end
        Recovers   = 'nie dotyczy'       # recovers without a human
        RtoS       = 'nie dotyczy'      # number = upper bound in seconds
        DataLoss   = 0         # rows lost
    }
}
