// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenseAssist",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CoreContracts", targets: ["CoreContracts"]),
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "RulesEngine", targets: ["RulesEngine"]),
        .library(name: "Planner", targets: ["Planner"]),
        .library(name: "LLMRuntime", targets: ["LLMRuntime"]),
        .library(name: "ParserPipeline", targets: ["ParserPipeline"]),
        .library(name: "Orchestration", targets: ["Orchestration"]),
        .library(name: "Ingestion", targets: ["Ingestion"]),
        .library(name: "SlackIntegration", targets: ["SlackIntegration"]),
        .library(name: "GmailIntegration", targets: ["GmailIntegration"]),
        .library(name: "OutlookIntegration", targets: ["OutlookIntegration"]),
        .library(name: "EventKitAdapter", targets: ["EventKitAdapter"]),
        .executable(name: "senseassist-helper", targets: ["SenseAssistHelper"]),
        .executable(name: "senseassist-menu", targets: ["SenseAssistMenuApp"])
    ],
    targets: [
        .target(name: "CoreContracts"),
        .target(name: "Storage", dependencies: ["CoreContracts"]),
        .target(name: "RulesEngine", dependencies: ["CoreContracts"]),
        .target(name: "Planner", dependencies: ["CoreContracts"]),
        .target(name: "LLMRuntime", dependencies: ["CoreContracts"]),
        .target(name: "ParserPipeline", dependencies: ["CoreContracts"]),
        .target(
            name: "Orchestration",
            dependencies: [
                "CoreContracts",
                "Planner",
                "RulesEngine",
                "SlackIntegration",
                "EventKitAdapter"
            ]
        ),
        .target(
            name: "Ingestion",
            dependencies: [
                "CoreContracts",
                "GmailIntegration",
                "ParserPipeline",
                "RulesEngine",
                "LLMRuntime",
                "Storage"
            ]
        ),
        .target(
            name: "SlackIntegration",
            dependencies: ["CoreContracts"],
            path: "Sources/Integrations/Slack"
        ),
        .target(
            name: "GmailIntegration",
            dependencies: ["CoreContracts"],
            path: "Sources/Integrations/Gmail"
        ),
        .target(
            name: "OutlookIntegration",
            dependencies: ["CoreContracts"],
            path: "Sources/Integrations/Outlook"
        ),
        .target(
            name: "EventKitAdapter",
            dependencies: ["CoreContracts"],
            path: "Sources/Integrations/EventKitAdapter"
        ),
        .executableTarget(
            name: "SenseAssistHelper",
            dependencies: [
                "CoreContracts",
                "Storage",
                "RulesEngine",
                "Planner",
                "LLMRuntime",
                "ParserPipeline",
                "Orchestration",
                "EventKitAdapter",
                "SlackIntegration",
                "Ingestion",
                "GmailIntegration"
            ]
        ),
        .executableTarget(
            name: "SenseAssistMenuApp",
            dependencies: ["CoreContracts", "Storage"]
        ),
        .testTarget(
            name: "CoreContractsTests",
            dependencies: ["CoreContracts"]
        ),
        .testTarget(
            name: "PlannerTests",
            dependencies: ["Planner", "CoreContracts"]
        ),
        .testTarget(
            name: "RulesEngineTests",
            dependencies: ["RulesEngine", "CoreContracts"]
        ),
        .testTarget(
            name: "StorageTests",
            dependencies: ["Storage", "CoreContracts"]
        ),
        .testTarget(
            name: "ParserPipelineTests",
            dependencies: ["ParserPipeline", "CoreContracts"]
        ),
        .testTarget(
            name: "OrchestrationTests",
            dependencies: [
                "Orchestration",
                "CoreContracts",
                "EventKitAdapter"
            ]
        ),
        .testTarget(
            name: "IngestionTests",
            dependencies: [
                "Ingestion",
                "CoreContracts",
                "GmailIntegration",
                "LLMRuntime",
                "Storage"
            ]
        )
    ]
)
