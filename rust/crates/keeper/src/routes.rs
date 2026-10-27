//! The agents that have an ACP route. `routes.json` is the table the app sends
//! to the python keeper (`agentRoutes` in `app/lib/data/acp/agent_host.dart`);
//! a Dart test keeps the two equal.

use serde::Deserialize;

/// One agent the keeper can start.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Route {
    /// Stable, lower case: `omp`, `claude`, `codex`, `pi`.
    pub id: String,
    /// What the person reads: `Claude Code`.
    pub label: String,
    pub binary: String,
    #[serde(default)]
    pub args: Vec<String>,
    /// Run through `npx -y` when the binary is not installed.
    #[serde(default)]
    pub npx: Option<String>,
    /// Capabilities declared to the agent (`clientCapabilities._meta.jetbrains.air`).
    #[serde(default)]
    pub air: Vec<String>,
}

const TABLE: &str = include_str!("../routes.json");

/// The routes, in the order the start form lists them.
///
/// # Panics
/// Never at run time: `routes.json` is checked by a test.
#[must_use]
pub fn all() -> Vec<Route> {
    serde_json::from_str(TABLE).expect("routes.json is valid, checked by a test")
}

/// The route with this id.
#[must_use]
pub fn by_id(id: &str) -> Option<Route> {
    all().into_iter().find(|r| r.id == id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_table_parses_and_ids_are_unique_lower_case() {
        let routes = all();
        assert_eq!(
            routes.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(),
            ["omp", "claude", "codex", "pi"]
        );
        for r in &routes {
            assert_eq!(r.id, r.id.to_lowercase());
        }
    }

    #[test]
    fn omp_runs_acp_and_the_others_can_fall_back_to_npx() {
        assert_eq!(by_id("omp").map(|r| r.args), Some(vec!["acp".to_string()]));
        assert!(all()
            .iter()
            .filter(|r| r.id != "omp")
            .all(|r| r.npx.is_some()));
        assert_eq!(by_id("nope"), None);
    }
}
