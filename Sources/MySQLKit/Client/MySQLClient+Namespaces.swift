public extension MySQLClient {
    var bulk: MySQLBulkOperationClient {
        MySQLBulkOperationClient(serverConnection: serverConnection)
    }

    var metadata: MySQLMetadataClient {
        MySQLMetadataClient(serverConnection: serverConnection)
    }

    var admin: MySQLAdminClient {
        MySQLAdminClient(serverConnection: serverConnection)
    }

    var security: MySQLSecurityClient {
        MySQLSecurityClient(serverConnection: serverConnection)
    }

    var session: MySQLSessionClient {
        MySQLSessionClient(serverConnection: serverConnection)
    }

    var performance: MySQLPerformanceClient {
        MySQLPerformanceClient(serverConnection: serverConnection)
    }

    var activity: MySQLActivityClient {
        MySQLActivityClient(serverConnection: serverConnection)
    }

    var replication: MySQLReplicationClient {
        MySQLReplicationClient(serverConnection: serverConnection)
    }

    var maintenance: MySQLMaintenanceClient {
        MySQLMaintenanceClient(serverConnection: serverConnection)
    }

    var indexes: MySQLIndexClient {
        MySQLIndexClient(serverConnection: serverConnection)
    }

    var views: MySQLViewClient {
        MySQLViewClient(serverConnection: serverConnection)
    }

    var routines: MySQLRoutineClient {
        MySQLRoutineClient(serverConnection: serverConnection)
    }

    var triggers: MySQLTriggerClient {
        MySQLTriggerClient(serverConnection: serverConnection)
    }

    var events: MySQLEventClient {
        MySQLEventClient(serverConnection: serverConnection)
    }

    var serverConfig: MySQLServerConfigClient {
        MySQLServerConfigClient(serverConnection: serverConnection)
    }

    var backupRestore: MySQLBackupRestoreClient {
        MySQLBackupRestoreClient(serverConnection: serverConnection)
    }

    var errorLog: MySQLErrorLogClient {
        MySQLErrorLogClient(serverConnection: serverConnection)
    }

    var constraints: MySQLConstraintClient {
        MySQLConstraintClient(serverConnection: serverConnection)
    }

    var scripts: MySQLScriptClient {
        MySQLScriptClient(serverConnection: serverConnection)
    }

    var executionPlan: MySQLExecutionPlanClient {
        MySQLExecutionPlanClient(serverConnection: serverConnection)
    }

    var transactions: MySQLTransactionClient {
        MySQLTransactionClient(serverConnection: serverConnection)
    }
}
