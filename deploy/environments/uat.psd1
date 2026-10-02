# User acceptance test environment.
# Only settings that are not secret belong here. The connection string comes from the
# DB_CONNECTION_STRING secret of the GitHub environment with the same name as this file.
@{
    AspNetCoreEnvironment = 'Uat'
    SiteName              = 'LendingApi'
    Port                  = 8085

    # Written into web.config as environment variables. "__" stands for ":" in a setting name.
    Settings              = @{
        'Logging__LogLevel__Default' = 'Information'
    }
}
