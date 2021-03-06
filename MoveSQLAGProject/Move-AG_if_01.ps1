# first check if 01 is primary then do failover but if 02 is primary then don't do failover

# Set Variables
$SQLServer = 'SOMESERVER'
$SQLDBName = 'SOMEDB'
$SMTPServer = ""
$messageFrom = ""
$messageTo = ""


# Set Preferences
$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"


function Send-MailonError {

    param (

        $SMTPServer,
        $messageFrom,
        $messageTo,
        $messageSubject,
        $messageBody

    )

    $params = @{

        SMTPServer = $SMTPServer
        Port       = 25
        From       = $messageFrom
        To         = $messageTo
        Subject    = $messageSubject
        Body       = $messageBody

    }

    Send-MailMessage @params 


}
function Start-SqlQuery {

    param (

        $SQLServer,
        $Database,
        $sqlQuery

    )

    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection

    if (!$Database) {

        $SqlConnection.ConnectionString = "Server = $SQLServer; Integrated Security = True;"

    }
    else {

        $SqlConnection.ConnectionString = "Server = $SQLServer; Database = $Database; Integrated Security = True;"

    }


    $SqlCmd = New-Object System.Data.SqlClient.SqlCommand
    $SqlCmd.CommandText = $sqlQuery
    $SqlCmd.Connection = $SqlConnection
    $SqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
    $SqlAdapter.SelectCommand = $SqlCmd
    $DataSet = New-Object System.Data.DataSet
    $SqlAdapter.Fill($DataSet) | Out-Null

    return $Dataset

}

try {


    # Get Server List
    $sqlQuery = "SET NOCOUNT ON;select Servername from Serverlist_AO with(nolock)"

    $params = @{

        SQLServer = $SQLServer
        Database  = $SQLDBName
        sqlQuery  = $sqlQuery

    }

    $DataSet = Start-SQLquery @params

    # Send Message if no data is received from query
    if (!$DataSet.tables.servername) {

        $messageBody = "No servers were received from server $SQLServer\$SQLDBName with the following Query: $sqlQuery"
        $messageSubject = "Error failing over AG for $SQLServer\$SQLDBName"

        $params = @{

            SMTPServer     = $SMTPServer
            messageFrom    = $messageFrom
            messageTo      = $messageTo
            messageSubject = $messageSubject
            messageBody    = $messageBody

        }
        Send-MailonError  @params

    }

    foreach ($server in $DataSet.tables.servername) {

        # Create SQL Query
        $sqlQuery = @'
SET NOCOUNT ON;
SELECT replica_server_name
FROM
sys.availability_groups_cluster AS AGC with(nolock)
INNER JOIN sys.dm_hadr_availability_replica_cluster_states AS RCS with(nolock)
ON
RCS.group_id = AGC.group_id
INNER JOIN sys.dm_hadr_availability_replica_states AS ARS with(nolock)
ON
ARS.replica_id = RCS.replica_id
INNER JOIN sys.availability_group_listeners AS AGL with(nolock)
ON
AGL.group_id = ARS.group_id where ARS.role_desc ='secondary'
'@


        $params = @{

            SQLServer = $server
            Database  = $null
            sqlQuery  = $sqlQuery
    
        }
    
        $DataSet = Start-SQLquery @params

        if (!$DataSet.Tables.replica_server_name) {


            $messageBody = "No failover AGs were received from server: $server with the following Query: $sqlQuery.  Failover did not occure"
            $messageSubject = "No failover AGs were received from server: $server"

            $params = @{

                SMTPServer     = $SMTPServer
                messageFrom    = $messageFrom
                messageTo      = $messageTo
                messageSubject = $messageSubject
                messageBody    = $messageBody
    
            }
            Send-MailonError  @param
        }
        else {
            $secondaryServer = $DataSet.Tables.replica_server_name

            if ($secondaryServer -match "01" ) {


                $sqlquery = @'
SET NOCOUNT ON; select distinct group_name from sys.dm_hadr_availability_replica_cluster_nodes with(nolock);
'@

                # Execute SQL Query to get AG Name

                $params = @{

                    SQLServer = $server
                    Database  = $null
                    sqlQuery  = $sqlQuery

                }

                $DataSet = Start-SQLquery @params
                $agName = $DataSet.Tables.group_name

                if (!$agName) {

                    $messageBody = "No availability group name was found for server $server with the following Query: $sqlQuery"
                    $messageSubject = "Error in failing over AG for $SQLServer\$SQLDBName"
        
                    $params = @{
        
                        SMTPServer     = $SMTPServer
                        messageFrom    = $messageFrom
                        messageTo      = $messageTo
                        messageSubject = $messageSubject
                        messageBody    = $messageBody
        
                    }
                    Send-MailonError  @params    

                }

                # Execute query to fail over the AG
        
                $sqlQuery = "ALTER AVAILABILITY GROUP [$agName] FAILOVER;"

                $params = @{

                    SQLServer = $secondaryServer
                    Database  = 'master'
                    sqlQuery  = $sqlQuery
        
                }
                
                Write-Verbose "Performing Failover to $secondaryServer with the query: $sqlQuery."
                $DataSet = Start-SQLquery @params

            }

        }
    }

}
catch {

    $messageBody = @"
    Exception During execution of Move-SecondaryAG: 

    Exception information is:   

    $Error[0]
    

    Current SQLQuery is:  $sqlQuery 

"@


    $messageSubject = "Error in failing over AG for $SQLServer\$SQLDBName"

    $params = @{

        SMTPServer     = $SMTPServer
        messageFrom    = $messageFrom
        messageTo      = $messageTo
        messageSubject = $messageSubject
        messageBody    = $messageBody

    }
    Send-MailonError  @params    
}