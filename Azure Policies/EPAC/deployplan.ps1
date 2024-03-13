$definitionsRootFolder = "C:\EPAC\Definitions"
$outputFolder = "C:\EPAC\Output"

Deploy-PolicyPlan -PacEnvironmentSelector "epac-dev" `
-DefinitionsRootFolder $definitionsRootFolder `
-inputFolder $outputFolder `
-Interactive

Deploy-RolesPlan `
-PacEnvironmentSelector "epac-dev" `
-DefinitionsRootFolder $definitionsRootFolder `
-inputFolder $outputFolder `
-Interactive