# ==============================================================================
# Tytul:        T04b_instance_abort_relocate.ps1
# Opis:         Definicja testu T4b dla tests/run_test.ps1: awaria jak w T4 (kill -9 PMON ggcdb1), a po 120 s
#               reczna interwencja dyzurnego: agctl relocate goldengate na ggrac2. Po T4 z 16.11: po upadku
#               instancji XAG nie idzie sam za serwisem (CRS-0222, crsd_excerpt.txt w T4-20261116-133519).
# Description [EN]: Definition of test T4b for tests/run_test.ps1: the T4 fault (kill -9 of PMON ggcdb1), then
#               after 120 s a manual on-call intervention: agctl relocate goldengate to ggrac2. After T4 on
#               16.11: after an instance crash XAG does not follow the service by itself (CRS-0222).
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.0
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - czyta ja tests/run_test.ps1; interwencja = wymaga -ApprovedBy
# Requirements [EN]: - read by tests/run_test.ps1; the intervention needs -ApprovedBy
#
# Uzycie [PL]:       .\tests\run_test.ps1 -Test T4b -ApprovedBy Kris [-Repeat 3]
# Usage [EN]:        .\tests\run_test.ps1 -Test T4b -ApprovedBy Kris [-Repeat 3]
# ==============================================================================
@{
    Id          = 'T4b'
    Title       = 'Instance abort + manual relocate'
    Kind        = 'abort'          # relocate, poweroff, abort, kill-sm, kill-ext, link-down, none
    Target      = 'ggcdb1'
    Variant     = 'manual-relocate' # video: tells T4b runs apart from T4
    Destructive = $false      # TESTS.md: may leave the lab broken
    Back        = $true      # needs a measured <test>-back run to the base state
    PreSec      = 60             # load before the fault
    PostSec     = 120            # observation after t_lag_ok
    TimeoutSec  = 600            # give up waiting for recovery
    # On-call reaction: 120 s after the fault (SM goes down at ~33 s), relocate GoldenGate to the service node
    # GoldenGate is already down at 120 s (T4: XAG OFFLINE at 33 s): agctl relocate needs a running resource,
    # so gg-move relocates when running, else starts on ggrac2 (oggvip moved with -f when the start is refused)
    # Kris 16.11 (recorded with OBS): the agent runs the move for Kris only after his live "tak" = file
    # approve_intervention in the run directory (approved_by=Kris); no approval within the limit = no move
    Intervention = @{ AfterSec = 120; Kind = 'gg-move'; Target = 'ggrac2'; LiveApproval = $true; ApprovalTimeoutSec = 600 }
    Notes       = 'As T4, then after 120 s by hand: GoldenGate moved to ggrac2 (agctl relocate or start).'
    # A4 (video): written to expected.json and summary.json before the fault; 'nie wiemy' = no guess
    Expected    = @{
        Hypothesis = 'After the relocate GoldenGate starts on ggrac2 with the service; VIP and ACFS move with it'
        Source     = 'T4-20261116-133519 (CRS-0222, no retry by CRS); agctl relocate as in T1'
        FinalNode  = 'ggrac2'      # GoldenGate node at the end
        Recovers   = 'nie dotyczy'   # recovers only with the intervention
        RtoS       = 'nie wiemy'      # number = upper bound in seconds
        DataLoss   = 0         # rows lost
    }
}
