# A failure the user must see (no account, no network, a wrong password) is reported as one error of the public
# command, through Write-ImapError, and the helper that met it returns $null or $false; it is not thrown.
# PowerShell adds every exception thrown and caught on the way to $Error and to the -ErrorVariable of the
# command, so a failure reported by throw and catch would read as several errors there. A configuration that
# cannot be read (accounts.json, IMAP_PORT) is still thrown: it stops the command, as it would any other.

# Reports a failure as an error of the public command running, whose $PSCmdlet is $Cmdlet
function Write-ImapError($Cmdlet, [string]$Message, [string]$ErrorId, [System.Management.Automation.ErrorCategory]$Category, $TargetObject) {
    $Cmdlet.WriteError([System.Management.Automation.ErrorRecord]::new([Exception]::new($Message), $ErrorId, $Category, $TargetObject))
}
