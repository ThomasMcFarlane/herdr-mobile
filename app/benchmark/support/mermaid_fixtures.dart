/// The diagrams the phone bench scrolls over: hand-written (nothing from
/// anyone's notes), one of each kind the app draws, a left-to-right flowchart
/// that turns, one that scrolls sideways, tall ones, and author fills. Sizes
/// span what the corpus holds (`tool/mermaid-bench`): from 4 to 30 nodes.
library;

String _chain(int n) => [for (var i = 0; i < n - 1; i++) '    N$i[Step $i: do the work] --> N${i + 1}[Step ${i + 1}: do the work]'].join('\n');

String _fan(int n) => [for (var i = 0; i < n; i++) '    Root[Root service] --> L$i[Leaf $i]'].join('\n');

/// Markdown, each entry one answer's worth: a line of prose and a fence.
final List<String> mermaidFixtures = [
  'The call flow:\n\n```mermaid\nflowchart TD\n    A[Start] --> B{Ok?}\n    B -->|yes| C[Ship]\n    B -->|no| D[Fix]\n    D --> A\n```',
  'A pipeline, left to right:\n\n```mermaid\nflowchart LR\n${_chain(8)}\n```',
  'Thirty nodes:\n\n```mermaid\nflowchart TD\n${_fan(30)}\n```',
  'Fourteen in a column:\n\n```mermaid\nflowchart TB\n${_chain(14)}\n```',
  'Author colours:\n\n```mermaid\nflowchart TD\n    A[Docs] --> B[Site]\n    A --> C[Blog]\n    style A fill:#e1f5fe\n    style B fill:#fff3e0\n    style C fill:#e8f5e9\n```',
  'Grouped:\n\n```mermaid\nflowchart TD\n    subgraph Front\n        W[Web] --> G[Gateway]\n    end\n    subgraph Back\n        S[Service] --> DB[(Database)]\n    end\n    G --> S\n```',
  'Three actors:\n\n```mermaid\nsequenceDiagram\n    participant A as App\n    participant B as Server\n    participant C as Database\n    A->>B: POST /login\n    B->>C: select user\n    C-->>B: row\n    B-->>A: token\n```',
  'Seven actors:\n\n```mermaid\nsequenceDiagram\n${[for (var i = 0; i < 7; i++) '    participant P$i as Participant $i'].join('\n')}\n    P0->>P6: hello\n    P6-->>P0: hi\n    Note over P0,P6: a long way across\n```',
  'States:\n\n```mermaid\nstateDiagram-v2\n    idle --> running: Start\n    running --> verifying: Completion detected\n    verifying --> running: Failed\n    verifying --> complete: Passed\n    running --> failed: Aborted\n```',
  'Tables:\n\n```mermaid\nerDiagram\n    USER ||--o{ ORDER : places\n    ORDER ||--|{ LINE_ITEM : contains\n    USER {\n        int id PK\n        string email UK\n    }\n    ORDER {\n        int id PK\n        int user_id FK\n    }\n```',
  'Types:\n\n```mermaid\nclassDiagram\n    class Animal {\n        +String name\n        +eat() void\n    }\n    Animal <|-- Dog\n    Animal <|-- Cat\n```',
  'A schedule, which stays code:\n\n```mermaid\ngantt\n    title Release\n    section Build\n    Compile :a1, 2024-01-01, 3d\n```',
];

/// Prose between diagrams, so the list is a chat and not a wall of plates.
const String mermaidProse =
    'The change touches three files and the tests around them. The first moves the parser behind its seam, the second '
    'stops the layout from running on the UI thread, and the third keeps the result between frames so a row that scrolls '
    'back in does not pay for it again.';
