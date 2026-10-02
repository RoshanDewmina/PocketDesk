"""Pure selector inventory for bounded claim audits and feature-only recovery."""
import argparse

# Matches RecoveryAuditGroup ranges in the existing UI test source. Home uses the
# previously added nine-surface supplemental methods; no new project source is needed.
GROUPS = {
    'entry': ('Entry', 7),
    'session': ('Session', 11),
    'help': ('Help', 6),
    'coach': ('Coach', 6),
    'display': ('Display', 1),
    'settings': ('Settings', 9),
    'errors1': ('Errors1', 8),
    'errors2': ('Errors2', 7),
    'home': ('SupplementalHomeUtilities', 9),
}
FEATURE_METHODS = [
    'ClaimsVerificationUITests/testCoachLessonsUseSynthesizedGesturesAllFive',
    'ClaimsVerificationUITests/testSessionPinchChangesAccessibleZoom',
    'ClaimsVerificationUITests/testKeyboardAndNonRecordingDictationRemainReachable',
    'ClaimsVerificationUITests/testOfflineConcealmentFixtureAndHomeBackgroundForeground',
    'FarsideRedesignUITests/testKeyboardBarPutsCommandFirstAndInReachInPortrait',
    'SessionLayoutTests/testLongVoicePreviewKeepsDoneReachableInLandscapeWithoutRecording',
]

# Exact existing phone-unit inventory (89 methods in ten selected classes).
# Reconcile this source-bound list when those tests change; skips/empty selections fail.
PHONE_UNIT_INVENTORY = {
    'FarsideDesignTests': [
        'testBundledFacesLoadUnderTheNamesTheThemeUses',
        'testDisplayHeadingKeepsPunctuationOutOfDoto',
        'testFriendlyErrorsExplainWhatTheConnectionReported',
        'testOnlyAReportFromTheMacSaysItIsAsleep',
        'testHomeStatusIsHonestAboutContact',
        'testScannerFeedbackNamesTheProblemWithoutAdmittingTheCode',
        'testPrimingIsExplainedOnceAndNeverDuringUITests',
        'testMicrophoneDoesNotPrimeAgainWhilePermissionsAreStillUndetermined',
        'testMoveLessonCompletesEvenWhenThePadResizesMidAttempt',
        'testEveryLessonCanBePassedThroughItsOwnGestures',
        'testCoachZoomAcceptsTheRealFingerPinchCommand',
        'testCoachLessonsRunOnALocalPadAndAdvanceInOrder',
    ],
    'SessionLifecycleTests': [
        'testArmedPiPReadsAsPlayingAndWaitsBrieflyInTheBackgroundForTheAutomaticStart',
        'testLeavingWhileArmedRestoresThePlaybackCategoryAfterDictation',
        'testLeavingALivePictureSessionStartsPiPAutomaticallyAndTheMacMustConfirmViewOnly',
        'testPiPRestoreKeepsThePlatformControllerAliveUntilTheCompletionReturns',
        'testActivePiPSurvivesInactiveHeartbeatThenBackgroundWithoutExitOrPause',
        'testBackgroundPiPPauseHoldsTheSessionAndResumeContinues',
        'testOpeningTheAppFromAPausedBackgroundPiPKeepsTheSession',
        'testControlCenterReturnKeepsSamePiPConsentAndLifetime',
        'testPiPRestoreWaitsForForegroundAndControlWaitsForExactExitACK',
        'testPendingPiPExitSurvivesRepeatedUnhealthyRetirementAndRejectsDuplicateACK',
        'testPiPRestoreTimeoutAndEndCannotResurrectRetiredSession',
        'testPiPRevokedDuringInactiveFailsClosedAndActuallyRequestsHostExit',
        'testAcceptedLockThenBackgroundAndActiveNeverHoldsResumesOrRetries',
        'testEditableFocusReplyOpensOnlyForNewestFreshClickOnce',
        'testEditableFocusReplyRejectsLateWrongEpochNoneditableAndDismissed',
        'testPointerFollowAcceptsValidRoundTripBeyondEightyMillisecondsAndStopsOnLift',
        'testPointerFollowKeepsZoomedTargetAboveOpenDock',
        'testInactiveInterruptionsShieldThePictureButKeepTheSession',
        'testBackgroundWithoutASessionConcealsTheSnapshotAndReturnsHome',
        'testBackgroundCancelsHeldInputAndPendingClipboardWork',
        'testConcealedRecoveryCanAlwaysReturnHome',
        'testMacReportedDeparturesAreExplainedWithoutGuessing',
        'testClipboardActionsExplainWhyTheyAreUnavailable',
        'testLaunchTransitionsBeforeFirstActivationDoNothing',
    ],
    'VoiceInputTests': [
        'testDismissedSheetNeverRequestsPermission',
        'testFinalRecognitionWaitsForExplicitDoneAndOnlyCompletesOnce',
        'testCancelDuringAuthorizationPreventsLateRecordingAndInsertion',
        'testInterruptionRetainsPartialTextWithoutAutomaticInsertion',
    ],
    'CommittedTextTests': [
        'testKeyboardDockOnlyInterceptsTouchesInsideItsHostedPanel',
        'testVoiceAcknowledgmentNeverClearsTypedDraftEvenWhenIdentical',
        'testFinalizedVoiceCanWaitForExplicitRetryWhenControlIsUnavailable',
        'testInitialFocusWaitsForAttachmentAndDoesNotStealFocusBack',
        'testDisabledOrRemovedEditorCannotTakeInitialFocus',
        'testDismissalRetainsNativeCompositionInLocalDraft',
        'testMarkedTextStaysLocalUntilCommitted',
        'testAcknowledgedDraftClearDoesNotRestoreOldText',
        'testPendingSendDisabledEnvironmentMakesNativeEditorReadOnly',
    ],
    'ExactTextTraitsTests': [
        'testExactTextTurnsOffEverythingThatRewritesTyping',
        'testProseKeepsSmartTyping',
        'testPasswordFieldIsExactAndSecureEvenInProse',
        'testComposerMasksWhatIsTypedIntoAPasswordField',
    ],
    'TabletInputPhoneTests': [
        'testActualPublicControllerRequestsButDoesNotAssumeSceneLockAndEndsOnce',
        'testNativeMouseOwnerGenerationRefusesOldHandlerAndNoLockRawDelta',
        'testActualPhonePencilContactUsesCausalStateBeforeDownAndLiftAndGeometryRetiresHold',
        'testKeyboardFocusReleaseWaitsForTheUpdateToFinish',
        'testUnderlyingCanvasUpdateCannotStealLockedKeyboardDisconnectOrFocus',
    ],
    'IndirectInputTests': [
        'testTheAppOptsIntoIndirectPointerTouches',
        'testTrackpadScrollAndPinchStillHaveTheirRecognizers',
    ],
    'ViewportPreferenceTests': [
        'testDefaultsToFillAndRemembersTheLastChoice',
        'testUnknownStoredValueFallsBackToFill',
    ],
    'ViewportCaptureTests': [
        'testTheFirstChangeLeavesAtOnceThenAtMostEvery100ms',
        'testASettledGestureLeavesAtOnce',
        'testAnUnchangedViewportKeepsItsEpochOnEveryHeartbeat',
        'testAViewportOfAnotherDisplayIsNeverSent',
        'testANewSessionResendsUnderAFreshEpoch',
        'testAPinchInsideTheStreamedAreaWaitsForTheSettle',
        'testAPinchThatRestsGetsItsCropWithoutLiftingAFinger',
        'testAContinuingPinchOutPastTheCropAsksForTwiceTheVisibleAreaOnce',
        'testAPanOrAOneOffChangePastTheCropGetsExactlyWhatItShows',
        'testAnotherDisplaysViewportLeavesAtOnce',
        'testAnOlderMacGetsTodaysHeartbeatPlusScreenPixels',
        'testTheViewportRidesOnHeartbeatsOnlyWhileTheMacAdvertisesIt',
        'testPhoneLoadRidesOnlyOnLadderHeartbeatsAndExpiresWithoutFreshStatistics',
        'testAHeartbeatWithAViewportPassesTheMacsValidation',
        'testAViewportHeartbeatKeepsThePointerAdvertisement',
        'testDisconnectedAndStoppedCallbacksCannotEnablePointerOrAdoptCrop',
        'testAZoomedViewportReachesTheHeartbeatInDisplayPoints',
        'testScreenPixelsAreTheNativeBoundsOnEveryHeartbeat',
        'testACaptureStatusRegionIsAdoptedOnlyForTheCurrentGeometry',
        'testTheCropCaptionIsCompact',
        'testThePointerGlyphAndACroppedFrameShareOnePlacement',
        'testATwoPercentAspectMismatchKeepsThePointerGlyphOnTarget',
        'testTheVideoFillsItsRegionOnlyWhileCropped',
        'testRegionEchoAndLadderStepKeepThePresentation',
    ],
    'ScreenRecordingApprovalPhoneTests': [
        'testTheMacsApprovalRefusalBecomesItsOwnStateWithExactSteps',
        'testDuringASessionTheMacsReasonBeatsTheGenericStoppedCapture',
        'testThePhoneAsksForTheApprovalReasonAndTheWidgetShowsIt',
    ],
}
PHONE_UNIT_METHODS = [suite+'/'+method for suite, methods in PHONE_UNIT_INVENTORY.items() for method in methods]

def parse_groups(value):
    if value == 'all':
        return list(GROUPS)
    groups = value.split(',')
    if not groups or len(set(groups)) != len(groups) or any(g not in GROUPS for g in groups):
        raise argparse.ArgumentTypeError('Use all or unique groups: ' + ','.join(GROUPS))
    return groups

def audit_methods(groups, size='both'):
    suffixes = {'both': ['DefaultSize', 'AccessibilityXXXL'],
                'default': ['DefaultSize'], 'AX-XXXL': ['AccessibilityXXXL']}[size]
    return ['ClaimsVerificationUITests/testAccessibilityAudit'
            + ('' if group == 'home' else 'Recovery') + GROUPS[group][0] + suffix
            for group in groups for suffix in suffixes]

def check_methods(family):
    if family not in {'phone', 'ipad'}:
        raise ValueError('Combined check requires phone or ipad')
    return (PHONE_UNIT_METHODS if family == 'phone' else []) + audit_methods(list(GROUPS)) + FEATURE_METHODS

def test_module(method):
    suite = method.split('/')[0]
    if suite in PHONE_UNIT_INVENTORY:
        return 'RemotePhoneTests'
    if suite in {'ClaimsVerificationUITests', 'FarsideRedesignUITests', 'SessionLayoutTests'}:
        return 'RemotePhoneUITests'
    raise ValueError('Unknown recovery test class: ' + suite)
