use crate::update::ToolCall;
use serde_json::{json, Value};

/// One choice a permission request offers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PermissionOption {
    pub id: String,
    pub name: String,
    /// `allow_once`, `allow_always`, `reject_once`, `reject_always` (or newer).
    pub kind: Option<String>,
}

impl PermissionOption {
    /// A grant that outlives this call: the person should have to mean it.
    #[must_use]
    pub fn is_standing(&self) -> bool {
        self.kind.as_deref().is_some_and(|k| k.ends_with("_always"))
    }
}

/// A `session/request_permission` request's params.
#[derive(Clone, Debug, PartialEq)]
pub struct PermissionRequest {
    pub tool_call: Option<ToolCall>,
    pub options: Vec<PermissionOption>,
}

impl PermissionRequest {
    /// Reads the params. Options without an `optionId` are dropped, as nothing
    /// could be answered with them.
    #[must_use]
    pub fn from_params(p: &Value) -> PermissionRequest {
        let options = p
            .get("options")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|o| {
                        let id = o.get("optionId")?.as_str()?.to_string();
                        let name = o
                            .get("name")
                            .and_then(Value::as_str)
                            .filter(|n| !n.is_empty())
                            .unwrap_or(&id)
                            .to_string();
                        let kind = o.get("kind").and_then(Value::as_str).map(str::to_string);
                        Some(PermissionOption { id, name, kind })
                    })
                    .collect()
            })
            .unwrap_or_default();
        PermissionRequest {
            tool_call: p.get("toolCall").and_then(ToolCall::from_value),
            options,
        }
    }
}

/// The `result` that answers a permission request with an option.
#[must_use]
pub fn outcome_selected(option_id: &str) -> Value {
    json!({"outcome": {"outcome": "selected", "optionId": option_id}})
}

/// The `result` that withdraws the answer (the request is cancelled).
#[must_use]
pub fn outcome_cancelled() -> Value {
    json!({"outcome": {"outcome": "cancelled"}})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn options_without_an_id_are_dropped_and_a_missing_name_falls_back_to_the_id() {
        let p = json!({"toolCall":{"toolCallId":"1","title":"Run ls"},
            "options":[{"optionId":"a","name":"Allow","kind":"allow_once"},{"name":"junk"},{"optionId":"b","kind":"allow_always"}]});
        let r = PermissionRequest::from_params(&p);
        assert_eq!(r.options.len(), 2);
        assert_eq!(r.options[1].name, "b");
        assert!(r.options[1].is_standing());
        assert!(!r.options[0].is_standing());
    }

    #[test]
    fn answers_have_the_shape_agents_expect() {
        assert_eq!(outcome_selected("a")["outcome"]["optionId"], "a");
        assert_eq!(outcome_cancelled()["outcome"]["outcome"], "cancelled");
    }
}
