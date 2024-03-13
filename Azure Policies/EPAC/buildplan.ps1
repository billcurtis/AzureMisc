$definitionsRootFolder = "C:\EPAC\Definitions"
$outputFolder = "C:\EPAC\Output"

Build-DeploymentPlans -PacEnvironmentSelector "epac-dev" `
-DevOpsType "ado" `
-DefinitionsRootFolder $definitionsRootFolder `
-OutputFolder $outputFolder `
-Interactive `
-Verbose

