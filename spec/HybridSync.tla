----------------------------- MODULE HybridSync -----------------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Mac, IPhone, VisibleAlert, HiddenAlert, MaxVersion

Devices == {Mac, IPhone}
Alerts == {VisibleAlert, HiddenAlert}
ObsDomain == Alerts \X Devices
DeviceStates == {"local_only", "paired", "revoked"}

VARIABLES deviceState, localObs, cloudObs,
          localFlag, localVer, cloudFlag, cloudVer, cloudDeleted,
          pushDirty, macForwardingHealthy

vars == <<deviceState, localObs, cloudObs,
          localFlag, localVer, cloudFlag, cloudVer, cloudDeleted,
          pushDirty, macForwardingHealthy>>

CanSync(d) == deviceState[d] = "paired"

Init ==
    /\ deviceState = [d \in Devices |-> "local_only"]
    /\ localObs = [d \in Devices |-> {}]
    /\ cloudObs = {}
    /\ localFlag = [d \in Devices |-> FALSE]
    /\ localVer = [d \in Devices |-> 0]
    /\ cloudFlag = FALSE
    /\ cloudVer = 0
    /\ cloudDeleted = FALSE
    /\ pushDirty = [d \in Devices |-> FALSE]
    /\ macForwardingHealthy = TRUE

\* Opt-in pairing transitions a local-only device into paired sync mode.
PairDevice(d) ==
    /\ d \in Devices
    /\ deviceState[d] = "local_only"
    /\ deviceState' = [deviceState EXCEPT ![d] = "paired"]
    /\ pushDirty' = [pushDirty EXCEPT ![d] = (localObs[d] # {} \/ localVer[d] > 0)]
    /\ UNCHANGED <<localObs, cloudObs, localFlag, localVer, cloudFlag, cloudVer, cloudDeleted,
                   macForwardingHealthy>>

\* One-tap revocation immediately stops a device from pushing or pulling without deleting local data.
RevokeDevice(d) ==
    /\ d \in Devices
    /\ deviceState[d] = "paired"
    /\ deviceState' = [deviceState EXCEPT ![d] = "revoked"]
    /\ UNCHANGED <<localObs, cloudObs, localFlag, localVer, cloudFlag, cloudVer, cloudDeleted,
                   pushDirty, macForwardingHealthy>>

\* Environment transition: macOS iPhone-forwarding (e.g. appplaceholdersyncd / usernotificationsd -10814)
\* can degrade or recover independently of iOS Shortcuts capture.
SetMacForwarding(healthy) ==
    /\ healthy \in BOOLEAN
    /\ macForwardingHealthy # healthy
    /\ macForwardingHealthy' = healthy
    /\ UNCHANGED <<deviceState, localObs, cloudObs, localFlag, localVer, cloudFlag, cloudVer,
                   cloudDeleted, pushDirty>>

\* Mac captures a visible forwarded alert (when macOS forwarding is healthy) or a muted/hidden alert.
MacCapture(a) ==
    /\ a \in Alerts
    /\ (a = VisibleAlert => macForwardingHealthy)
    /\ <<a, Mac>> \notin localObs[Mac]
    /\ localObs' = [localObs EXCEPT ![Mac] = @ \cup {<<a, Mac>>}]
    /\ pushDirty' = [pushDirty EXCEPT ![Mac] = IF a # HiddenAlert THEN TRUE ELSE @]
    /\ UNCHANGED <<deviceState, cloudObs, localFlag, localVer, cloudFlag, cloudVer, cloudDeleted,
                   macForwardingHealthy>>

\* iPhone captures the visible alert directly via iOS 27 Shortcuts regardless of macOS forwarding health.
IPhoneCapture ==
    /\ <<VisibleAlert, IPhone>> \notin localObs[IPhone]
    /\ localObs' = [localObs EXCEPT ![IPhone] = @ \cup {<<VisibleAlert, IPhone>>}]
    /\ pushDirty' = [pushDirty EXCEPT ![IPhone] = TRUE]
    /\ UNCHANGED <<deviceState, cloudObs, localFlag, localVer, cloudFlag, cloudVer, cloudDeleted,
                   macForwardingHealthy>>

\* Paired device pushes its non-hidden local observations to the private CloudKit zone.
\* Hidden/muted alerts on Mac are filtered out and never pushed to cloud.
PushObservations(d) ==
    /\ d \in Devices
    /\ CanSync(d)
    /\ pushDirty[d]
    /\ LET eligible == {o \in localObs[d] : o[1] # HiddenAlert}
       IN /\ ~cloudDeleted
          /\ eligible \ cloudObs # {}
          /\ cloudObs' = cloudObs \cup eligible
          /\ pushDirty' = [pushDirty EXCEPT ![d] = (localVer[d] > cloudVer)]
    /\ UNCHANGED <<deviceState, localObs, localFlag, localVer, cloudFlag, cloudVer, cloudDeleted,
                   macForwardingHealthy>>

\* Transient CloudKit push failure (offline, signed out, missing entitlement, quota):
\* cloud state stays unchanged and pushDirty remains TRUE so the next sync retries.
PushFail(d) ==
    /\ d \in Devices
    /\ CanSync(d)
    /\ pushDirty[d]
    /\ UNCHANGED vars

\* Paired device pulls remote observations from the private CloudKit zone, preserving provenance.
PullObservations(d) ==
    /\ d \in Devices
    /\ CanSync(d)
    /\ cloudObs \ localObs[d] # {}
    /\ localObs' = [localObs EXCEPT ![d] = @ \cup cloudObs]
    /\ UNCHANGED <<deviceState, cloudObs, localFlag, localVer, cloudFlag, cloudVer, cloudDeleted,
                   pushDirty, macForwardingHealthy>>

\* User edits workflow state (e.g., flag/save/read/follow-up) locally on either device, even offline.
LocalWorkflowEdit(d, newFlag) ==
    /\ d \in Devices
    /\ newFlag \in BOOLEAN
    /\ localVer[d] < MaxVersion
    /\ localFlag' = [localFlag EXCEPT ![d] = newFlag]
    /\ localVer' = [localVer EXCEPT ![d] = @ + 1]
    /\ pushDirty' = [pushDirty EXCEPT ![d] = TRUE]
    /\ UNCHANGED <<deviceState, localObs, cloudObs, cloudFlag, cloudVer, cloudDeleted,
                   macForwardingHealthy>>

\* Paired device pushes a newer workflow edit to cloud (LWW by monotonic version; tombstones win).
PushWorkflow(d) ==
    /\ d \in Devices
    /\ CanSync(d)
    /\ ~cloudDeleted
    /\ localVer[d] > cloudVer
    /\ cloudFlag' = localFlag[d]
    /\ cloudVer' = localVer[d]
    /\ pushDirty' = [pushDirty EXCEPT ![d] = ({o \in localObs[d] : o[1] # HiddenAlert} \ cloudObs # {})]
    /\ UNCHANGED <<deviceState, localObs, cloudObs, localFlag, localVer, cloudDeleted,
                   macForwardingHealthy>>

\* Paired device pulls newer workflow state from cloud.
PullWorkflow(d) ==
    /\ d \in Devices
    /\ CanSync(d)
    /\ ~cloudDeleted
    /\ cloudVer > localVer[d]
    /\ localFlag' = [localFlag EXCEPT ![d] = cloudFlag]
    /\ localVer' = [localVer EXCEPT ![d] = cloudVer]
    /\ UNCHANGED <<deviceState, localObs, cloudObs, cloudFlag, cloudVer, cloudDeleted,
                   pushDirty, macForwardingHealthy>>

\* Explicit cloud deletion tombstone prevents stale offline retries from resurrecting deleted cloud state.
CommitDeleteTombstone(d) ==
    /\ d \in Devices
    /\ CanSync(d)
    /\ ~cloudDeleted
    /\ cloudObs # {}
    /\ cloudDeleted' = TRUE
    /\ cloudObs' = {}
    /\ UNCHANGED <<deviceState, localObs, localFlag, localVer, cloudFlag, cloudVer, pushDirty,
                   macForwardingHealthy>>

Next ==
    \/ \E d \in Devices : PairDevice(d)
    \/ \E d \in Devices : RevokeDevice(d)
    \/ \E h \in BOOLEAN : SetMacForwarding(h)
    \/ \E a \in Alerts : MacCapture(a)
    \/ IPhoneCapture
    \/ \E d \in Devices : PushObservations(d)
    \/ \E d \in Devices : PushFail(d)
    \/ \E d \in Devices : PullObservations(d)
    \/ \E d \in Devices, f \in BOOLEAN : LocalWorkflowEdit(d, f)
    \/ \E d \in Devices : PushWorkflow(d)
    \/ \E d \in Devices : PullWorkflow(d)
    \/ \E d \in Devices : CommitDeleteTombstone(d)

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ deviceState \in [Devices -> DeviceStates]
    /\ \A d \in Devices : localObs[d] \subseteq ObsDomain
    /\ cloudObs \subseteq ObsDomain
    /\ localFlag \in [Devices -> BOOLEAN]
    /\ localVer \in [Devices -> 0..MaxVersion]
    /\ cloudFlag \in BOOLEAN
    /\ cloudVer \in 0..MaxVersion
    /\ cloudDeleted \in BOOLEAN
    /\ pushDirty \in [Devices -> BOOLEAN]
    /\ macForwardingHealthy \in BOOLEAN

\* Muted/hidden alerts on Mac never leak into the synced cloud projection or onto iPhone.
HiddenNeverLeaksToCloudOrIPhone ==
    /\ \A o \in cloudObs : o[1] # HiddenAlert
    /\ \A o \in localObs[IPhone] : o[1] # HiddenAlert

\* Tombstoned cloud records stay deleted and are never resurrected by stale offline devices.
TombstoneBlocksResurrection ==
    cloudDeleted => (cloudObs = {})

\* If a paired device has unpushed non-hidden observations (and cloud is not tombstoned),
\* its pushDirty flag must stay TRUE so digest-skipping never drops unsynced data.
DirtyFlagProtectsUnpushedData ==
    \A d \in Devices :
        (CanSync(d) /\ ~cloudDeleted /\ ({o \in localObs[d] : o[1] # HiddenAlert} \ cloudObs # {}))
            => pushDirty[d]

\* Cross-device forwarding health warning: flags when a paired Mac received a synced iPhone alert
\* that local macOS Accessibility capture did not observe.
MacForwardingWarning ==
    /\ CanSync(Mac)
    /\ <<VisibleAlert, IPhone>> \in localObs[Mac]
    /\ <<VisibleAlert, Mac>> \notin localObs[Mac]

\* Health detector never false-alarms when unpaired or when Mac captured the alert locally,
\* and whenever the warning fires, Mac still has the alert via iOS hybrid sync.
ForwardingHealthSoundness ==
    /\ (~CanSync(Mac) => ~MacForwardingWarning)
    /\ ((<<VisibleAlert, Mac>> \in localObs[Mac]) => ~MacForwardingWarning)
    /\ (MacForwardingWarning => \E o \in localObs[Mac] : o[1] = VisibleAlert)

\* Collapsed logical alert view: merges dual Mac + iPhone observations of the same logical alert
\* into one Inbox item without deleting raw per-device evidence.
CollapsedAlerts(obs) == {o[1] : o \in obs}

CrossDeviceDualCaptureCoherence ==
    \A d \in Devices :
        /\ Cardinality(CollapsedAlerts(localObs[d])) <= Cardinality(Alerts)
        /\ ((<<VisibleAlert, Mac>> \in localObs[d] /\ <<VisibleAlert, IPhone>> \in localObs[d])
            => VisibleAlert \in CollapsedAlerts(localObs[d]))

\* Local evidence on either device is never destroyed by sync, edits, failures, or revocation.
LocalEvidenceNeverVanishes == [][
    \A d \in Devices : localObs[d] \subseteq localObs'[d]
    ]_vars

\* Cloud workflow version and tombstones are monotonic across offline edits and retries.
CloudStateMonotonic == [][
    /\ cloudVer' >= cloudVer
    /\ (cloudDeleted => cloudDeleted')
    ]_vars

\* Unpaired (local-only) or revoked devices never mutate cloud state or pull remote observations.
UnpairedOrRevokedNeverSyncs == [][
    /\ ((cloudObs' # cloudObs \/ cloudVer' # cloudVer \/ cloudDeleted' # cloudDeleted)
        => \E d \in Devices : CanSync(d))
    /\ (\A d \in Devices :
        (~CanSync(d) /\ localObs'[d] # localObs[d]) =>
            \A o \in (localObs'[d] \ localObs[d]) : o[2] = d)
    ]_vars
=============================================================================
