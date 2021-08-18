#Requires -Modules AWSPowerShell

<#
.Synopsis
Monitor for files in a given directory
.DESCRIPTION
Monitor files in a given directory and if any files persists for longer than the time specified, 
this script will raise a CloudWatch alert.
.EXAMPLE
Example of how to use this cmdlet
.EXAMPLE
Another example of how to use this cmdlet
#>


#-----------------------------
# Parameters
#-----------------------------

[CmdletBinding()]
Param()



#-----------------------------
# Variables
#-----------------------------

$ConfigurationFilePath = "$pwd\OldFileMonitor.json"

#-----------------------------
# Functions
#-----------------------------

# taken from: https://github.carboniteinc.com/briwel/hack/blob/master/cloudwatch/windowsServiceMonitor.ps1
#Write the metric to AWS Cloudwatch
Function WriteCWMetric
{
    Param(
        [int]
        $FileCount, # formerly $ServiceValue

        [string]
        $FolderPath, # formerly $ServiceName

        [string]
        $EC2Name,

        [string]
        $InstanceID
    )
  
    $dimension = New-Object Amazon.CloudWatch.Model.Dimension
    $dimension.set_Name("InstanceId")
    $dimension.set_Value($InstanceID)
  
    $dimension2 = New-Object Amazon.CloudWatch.Model.Dimension
    $dimension2.set_Name("FolderPath")
    $dimension2.set_Value($FolderPath)
  
    $dimension3 = New-Object Amazon.CloudWatch.Model.Dimension
    $dimension3.set_Name("InstanceName")
    $dimension3.set_Value($EC2Name)
  
    $dat = New-Object Amazon.CloudWatch.Model.MetricDatum
    $dat.Dimensions = $dimension, $dimension2, $dimension3
    $dat.Timestamp = (Get-Date).ToUniversalTime()
    $dat.MetricName = "OldFileCount"
    $dat.Unit = "Count"
    $dat.Value = $FileCount

    Write-CWMetricData -Namespace "Windows/Default" -MetricData $dat
    Write-Host "Folder $FolderPath has $FileCount old files Metric sent to Cloudwatch"
}



<#
.Synopsis
Find files in a provided directory that are older than the specified time interval
.EXAMPLE
Get-OldFilesInFolder -Path C:\Temp -TimeInterval 3d

If the C:\temp directory has 5 files that are older than 3 days you will get back the following PSCustomObject:

(Assuming [datetime]::now is 8/6/2021 1:52:49 PM)

Path        : C:\Temp
timeInterval: 3d
OldTime     : 8/3/2021 1:52:49 PM
OldFiles    : 5
#>
function Get-OldFilesInFolder
{
    [CmdletBinding()]
    Param
    (
        # Param1 help description
        [Parameter(Mandatory = $true,
            ValueFromPipeline = $true,
            HelpMessage = "Path to one or more directories (not files).",
            Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $Path,

        # Param2 help description
        [Parameter(Mandatory = $true,
            HelpMessage = "Pattern: '<number><Interval>' where 'Interval' is s,m,h,d,w,M,y s=seconds, m=minutes, h=hour...",
            Position = 1)]
        [ValidatePattern("[0-9]+[smhdwMy]")]
        [string]
        $TimeInterval
    )

    Begin
    {
        if (-not ($TimeInterval -match "(?<Number>[0-9]+)(?<TimeInterval>[smhdwMy])"))
        {
            $Exception = New-Object System.ArgumentException ('Invalid argument provided.', 'Time')
            $ErrorCategory = [System.Management.Automation.ErrorCategory]::InvalidArgument
            # Exception, ErrorId as [string], Category, and TargetObject (e.g. the parameter that was invalid)
            $ErrorRecord = New-Object System.Management.Automation.ErrorRecord($Exception, 'InvalidArgument', $ErrorCategory, $null)
            $PSCmdlet.ThrowTerminatingError($ErrorRecord)
        }
    }
    Process
    {
        $Oldfiles = 0                   # A count of "old files" that have been found
        $OldTime = [datetime]::now      # The time at which files created before this date are considered 'old'


        # set the datetime where files are considered 'old'
        switch -casesensitive ($matches['timeinterval'])
        {
            s
            { $OldTime = (get-date).Addseconds((-1 * $matches['number']))    ; break}
            m
            { $OldTime = (get-date).AddMinutes((-1 * $matches['number']))    ; break}
            h
            { $OldTime = (get-date).Addhours((-1 * $matches['number']))      ; break}
            d
            { $OldTime = (get-date).AddDays((-1 * $matches['number']))       ; break}
            w
            { $OldTime = (get-date).addDays((-1 * ($matches['number'] * 7))) ; break}
            M
            { $OldTime = (get-date).AddMonths((-1 * $matches['number']))     ; break}
            y
            { $OldTime = (get-date).Addyears((-1 * $matches['number']))      ; break}

            Default
            {
                $Exception = New-Object System.ArgumentException ('Invalid argument provided.', 'Time')
                $ErrorCategory = [System.Management.Automation.ErrorCategory]::InvalidArgument
                # Exception, ErrorId as [string], Category, and TargetObject (e.g. the parameter that was invalid)
                $ErrorRecord = New-Object System.Management.Automation.ErrorRecord($Exception, 'InvalidArgument', $ErrorCategory, $null)
                $PSCmdlet.ThrowTerminatingError($ErrorRecord)
            }
        }

        # loop through each given path
        foreach ($directory in $Path)
        {
            # reset oldfiles
            $Oldfiles = 0

            Write-Verbose "[$(Get-Date -format G)] Validating path ($directory)"

            # Confirm the given path is to a directory and not a file. If not, skip with an error.
            if ( (get-item $directory -ErrorAction 'SilentlyContinue') -isnot [System.IO.DirectoryInfo] )
            {
                Write-Error "Provided path is not a directory path: $directory"

                [psobject][ordered] @{
                    Path         = $directory
                    timeInterval = $TimeInterval
                    OldTime      = $(get-date $OldTime -format G)
                    OldFiles     = -1
                }
            
                Continue
            }

            # # Confirm the given path is valid. if so, skip it with an error.
            # if (-not (test-path $directory -ErrorAction 'SilentlyContinue'))
            # {
            #     Write-Error "Provided path does not exist: $directory"                

            #     [psobject][ordered] @{
            #         Path         = $directory
            #         timeInterval = $TimeInterval
            #         OldTime      = $(get-date $OldTime -format G)
            #         OldFiles     = -1
            #     }

            #     Continue
            # }

            Write-Verbose "[$(Get-Date -format G)]  - path validated ($directory)"

            # Loop through each file within the given directory (not recursively)
            $FilesInDirectory = Get-ChildItem -path $directory -File -ErrorAction 'SilentlyContinue' | sort creationtime
            Write-Verbose "[$(Get-Date -format G)] There are $($FilesInDirectory | measure | % count) files in path $directory"

            $fileNumber = 1
            foreach ($file in $FilesInDirectory)
            {
                if ($file.CreationTime -lt $OldTime)
                {
                    write-verbose "$($fileNumber.tostring('0000'))`. $($file.CreationTime.toString('MM/dd/yyyy HH:mm:ss')) -lt $(get-date $OldTime.toString('MM/dd/yyyy HH:mm:ss')) $($file.fullname))"
                    $Oldfiles++
                }
                else
                {
                    write-verbose "$($fileNumber.tostring('0000'))`. $(get-date $file.CreationTime.tostring('MM/dd/yyyy HH:mm:ss')) -GT $(get-date $OldTime.tostring('MM/dd/yyyy HH:mm:ss')) $($file.fullname))"
                }
                
                $fileNumber++
            }

            [psCustomObject][ordered] @{
                Path         = $directory
                timeInterval = $TimeInterval
                OldTime      = $(get-date $OldTime -format G)
                OldFiles     = $OldFiles
            }
        }
    }
    End
    {
    }
}

#-----------------------------
# Main
#-----------------------------

$InstanceID = Invoke-RestMethod -uri http://169.254.169.254/latest/meta-data/instance-id
$EC2Name = $env:COMPUTERNAME.ToLower()

# get the parameters from the configuration file
$parameters = gc $ConfigurationFilePath | ConvertFrom-Json

# Create a collection of results
$ResultSet = [System.Collections.ArrayList]::new()

# Loop through each parameter set in the configuration file
foreach ( $parameterSet in $Parameters)
{
    $Path = $parameterset.Path
    $TimeInterval = $parameterset.TimeInterval
    
    # Get the results of each check.
    $null = $ResultSet.AddRange( @($( Get-OldFilesInFolder $path $TimeInterval -Verbose ) ) )
}

# Loop through all the results and write to CloudWatch
foreach ($Result in $ResultSet)
{
    $params = @{
        FileCount  = $Result.OldFiles
        FolderPath = $Result.Path
        EC2Name    = $EC2Name
        InstanceId = $InstanceID
    }

    Write-Verbose "[$(Get-Date -format G)] FolderPath = $($Result.Path) // FileCount  = $($Result.OldFiles)"
        
    try 
    {
        WriteCWMetric @params -ErrorAction 'Stop'
    }
    catch 
    {
        Exit 99
    }
}