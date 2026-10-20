"""Narrow Mac regression scope: reviewed unavailable database roots only.

These exact Go root symbols call absent-fixture guards. This allow-list is not
inferred from filenames, package names or caller-supplied reasons at runtime.
Every retained root remains uncovered and needs the separate DB/TLS proof layer.
"""

POLICY = 'macos-swiftui-shared-nondatabase-v1'
UNAVAILABLE_DATABASE_ROOTS = frozenset({
    'dbeer/helper/cmd/dbeer-core/TestPostgresBackpressureControlWithSixteenRealSessions',
    'dbeer/helper/cmd/dbeer-core/TestPostgresConnectionLifecycle',
    'dbeer/helper/internal/mysql/TestMySQLBrowsePagingFiltersAndStableCompositeOrder',
    'dbeer/helper/internal/mysql/TestMySQLCancelAndTimeoutPreserveNextQuery',
    'dbeer/helper/internal/mysql/TestMySQLCatalogReadOnlyReasonsAndDeletedObjects',
    'dbeer/helper/internal/mysql/TestMySQLCatalogRealObjectsAndStableBrowse',
    'dbeer/helper/internal/mysql/TestMySQLCatalogStreamsBoundedUnicodeIdentitiesBeforeCopyName',
    'dbeer/helper/internal/mysql/TestMySQLChangesCancellationRollsBackBeforeReturning',
    'dbeer/helper/internal/mysql/TestMySQLChangesCompositeDefaultsGeneratedAndTypedSnapshot',
    'dbeer/helper/internal/mysql/TestMySQLChangesConflictMissingAndConstraintRollback',
    'dbeer/helper/internal/mysql/TestMySQLChangesDeadlockRollsBackOneCompleteBatch',
    'dbeer/helper/internal/mysql/TestMySQLChangesLostCommitAckIsUnknownAndNeverRepeated',
    'dbeer/helper/internal/mysql/TestMySQLChangesRejectReadOnlyTablesAndActiveSQLTransaction',
    'dbeer/helper/internal/mysql/TestMySQLCompletedStatementRemainsSuccessfulAfterCancelRequest',
    'dbeer/helper/internal/mysql/TestMySQLConnectionLossReportsUnknownOutcome',
    'dbeer/helper/internal/mysql/TestMySQLErrorRecoveryReportsImplicitCommit',
    'dbeer/helper/internal/mysql/TestMySQLExportCollisionAndCancellationPreserveExistingTarget',
    'dbeer/helper/internal/mysql/TestMySQLFailedControlAndServerMismatchCloseSession',
    'dbeer/helper/internal/mysql/TestMySQLIndependentTransactionsTemporaryTablesAndValues',
    'dbeer/helper/internal/mysql/TestMySQLJSONExportIsCompleteAndRunsVolatileSQLOnce',
    'dbeer/helper/internal/mysql/TestMySQLLateControlNeverCancelsNextExecution',
    'dbeer/helper/internal/mysql/TestMySQLProcedureLateErrorPreservesCompletedResult',
    'dbeer/helper/internal/mysql/TestMySQLProcedureMultipleResultsAndFinalStatus',
    'dbeer/helper/internal/mysql/TestMySQLProcedureResultLimitsApplyAcrossAllSets',
    'dbeer/helper/internal/mysql/TestMySQLReadOnlyServerModeAndTransactionGuard',
    'dbeer/helper/internal/mysql/TestMySQLSinkReceivesAllRowsBeforePreviewTruncation',
    'dbeer/helper/internal/mysql/TestMySQLStreamingLimitsDrainBeforeNextExecution',
    'dbeer/helper/internal/mysql/TestMySQLTLS',
    'dbeer/helper/internal/mysql/TestMySQLTypedTableBrowsePagesFiltersAndUnstableViewOrder',
    'dbeer/helper/internal/postgres/TestChangesCancellationRollsBackAndRecoversItsConnection',
    'dbeer/helper/internal/postgres/TestChangesCompositePrimaryKeyDefaultsGeneratedBinaryNullAndExactNumeric',
    'dbeer/helper/internal/postgres/TestChangesConflictAndMissingRowRollBackEarlierOperations',
    'dbeer/helper/internal/postgres/TestChangesConstraintFailureGeneratedColumnsAndReadOnlyReasons',
    'dbeer/helper/internal/postgres/TestChangesDeadlockRollsBackTheEntireApplyWithoutRetry',
    'dbeer/helper/internal/postgres/TestChangesDeferredConstraintFailureAtCommitIsAKnownRollback',
    'dbeer/helper/internal/postgres/TestChangesGeneratedOnlyColumnsAllowDefaultInsertAndDeleteWithIncludedPrimaryKeyColumns',
    'dbeer/helper/internal/postgres/TestChangesLostCommitAcknowledgementIsUnknownAndNeverRepeated',
    'dbeer/helper/internal/postgres/TestChangesQuotedIdentifiersAndValuesNeverBecomeSQL',
    'dbeer/helper/internal/postgres/TestChangesRevalidatesMetadataAfterWaitingForConcurrentDDL',
    'dbeer/helper/internal/postgres/TestPostgresErrorPositionCountsUnicodeScalars',
    'dbeer/helper/internal/postgres/TestPostgresExecuteCancelAndBusyGuards',
    'dbeer/helper/internal/postgres/TestPostgresExecuteCancelRaceCannotCancelNextQuery',
    'dbeer/helper/internal/postgres/TestPostgresExecuteConnectionLossInvalidatesSession',
    'dbeer/helper/internal/postgres/TestPostgresExecuteDrainsRowsPastDisplayLimits',
    'dbeer/helper/internal/postgres/TestPostgresExecuteKeepsOneSessionForDDLDMLAndTransactions',
    'dbeer/helper/internal/postgres/TestPostgresExecutePreservesTextAndColumnIdentity',
    'dbeer/helper/internal/postgres/TestPostgresExecuteRejectsMultipleStatementsWithoutPartialExecution',
    'dbeer/helper/internal/postgres/TestPostgresExecuteRejectsUnsupportedCopyWithoutEnteringCopyMode',
    'dbeer/helper/internal/postgres/TestPostgresExecuteShutdownAndEOFReleaseActiveBackend',
    'dbeer/helper/internal/postgres/TestPostgresExecuteTimeoutDisconnectsWhenCancellationCannotRecover',
    'dbeer/helper/internal/postgres/TestPostgresExecuteTimeoutKeepsConnection',
    'dbeer/helper/internal/postgres/TestPostgresReadOnlyServerModeAndTransactionGuard',
    'dbeer/helper/internal/postgres/TestPostgresReadonlyBoundsHiddenBuiltinOverloadEffects',
    'dbeer/helper/internal/postgres/TestPostgresTLSNegotiation',
    'dbeer/helper/internal/session/TestPostgresCatalogObjectsDefinitionsAndQuotedBrowse',
    'dbeer/helper/internal/session/TestPostgresCopyNameQuotesEveryObjectKindWithoutExecutingIt',
    'dbeer/helper/internal/session/TestPostgresRunToFileExecutesOnceAndPublishesOnlyConfirmedSuccess',
    'dbeer/helper/internal/session/TestPostgresSessionLossInvalidatesOnlyItsOwnSession',
    'dbeer/helper/internal/session/TestPostgresSessionsConnectAndStopWhileOtherQueriesRemainActive',
    'dbeer/helper/internal/session/TestPostgresSessionsKeepIndependentTransactionsSettingsAndTempTables',
    'dbeer/helper/internal/session/TestPostgresStreamingBoundsBinaryAndPaging',
    'dbeer/helper/internal/session/TestPostgresTypedTableBrowsePagesFiltersAndMissingObject',
})


def coverage(proof):
    ignored = proof.get('ignored', [])
    if not isinstance(ignored, list) or any(not isinstance(name, str) for name in ignored):
        raise ValueError('Exact Mac skip symbols are required.')
    skipped = set(ignored)
    return {'policy': POLICY, 'uncoveredDatabaseRoots': sorted(skipped & UNAVAILABLE_DATABASE_ROOTS),
            'unapprovedSkips': sorted(skipped - UNAVAILABLE_DATABASE_ROOTS),
            'separateCompletedDatabaseTLSLayersRequired': True,
            'nativeWindowsLinuxCoverageEstablished': False}
