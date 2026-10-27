//! Session config options: the model, the mode, the thinking level. An agent reports them in
//! the answer to `session/new` and `session/load`, and again in a `config_option_update`.

use serde_json::Value;

/// One select option of the session (booleans and unknown kinds are not kept).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConfigOption {
    pub id: String,
    pub name: String,
    /// `model`, `mode`, `thought_level`, ... when the agent says.
    pub category: Option<String>,
    /// The value currently chosen.
    pub current: Option<String>,
    /// `(value, name)` of every choice, groups flattened.
    pub choices: Vec<(String, String)>,
    /// From the older `models` shape, which has no `session/set_config_option` contract: shown,
    /// never changed from here.
    pub legacy: bool,
}

impl ConfigOption {
    /// Whether this is the option called `what`, by id or by category.
    #[must_use]
    pub fn is(&self, what: &str) -> bool {
        self.id == what || self.category.as_deref() == Some(what)
    }

    /// What the person reads for the current choice: its name, else its value.
    #[must_use]
    pub fn current_name(&self) -> Option<&str> {
        let cur = self.current.as_deref()?;
        Some(
            self.choices
                .iter()
                .find(|(v, _)| v == cur)
                .map_or(cur, |(_, n)| n.as_str()),
        )
    }
}

fn s<'v>(v: &'v Value, k: &str) -> Option<&'v str> {
    v.get(k)?.as_str()
}

fn choices(options: &Value, out: &mut Vec<(String, String)>) {
    for o in options.as_array().into_iter().flatten() {
        if o.get("group").is_some() || o.get("options").is_some() {
            choices(&o["options"], out);
        } else if let Some(value) = s(o, "value") {
            out.push((value.to_string(), s(o, "name").unwrap_or(value).to_string()));
        }
    }
}

/// The select options in `v` (a `configOptions` array).
#[must_use]
pub fn parse_config_options(v: &Value) -> Vec<ConfigOption> {
    v.as_array()
        .into_iter()
        .flatten()
        .filter(|o| s(o, "type") == Some("select"))
        .filter_map(|o| {
            let id = s(o, "id")?.to_string();
            let mut ch = Vec::new();
            choices(&o["options"], &mut ch);
            Some(ConfigOption {
                name: s(o, "name").unwrap_or(&id).to_string(),
                category: s(o, "category").map(str::to_string),
                current: s(o, "currentValue").map(str::to_string),
                id,
                choices: ch,
                legacy: false,
            })
        })
        .collect()
}

/// The older shape: `models: {currentModelId, availableModels: [{modelId, name}]}`, as the model option.
#[must_use]
pub fn legacy_models(result: &Value) -> Option<ConfigOption> {
    let m = result.get("models")?;
    let current = s(m, "currentModelId")?.to_string();
    let choices = m
        .get("availableModels")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|a| {
            Some((
                s(a, "modelId")?.to_string(),
                s(a, "name")
                    .unwrap_or_else(|| s(a, "modelId").unwrap_or(""))
                    .to_string(),
            ))
        })
        .collect();
    Some(ConfigOption {
        id: "model".into(),
        name: "Model".into(),
        category: Some("model".into()),
        current: Some(current),
        choices,
        legacy: true,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_select_option_gives_its_current_choice_by_name() {
        let v = json!([
            {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "gpt-5",
             "options": [{"value": "gpt-5", "name": "GPT-5"}, {"value": "o3", "name": "o3"}]},
            {"id": "flag", "type": "boolean", "currentValue": true}
        ]);
        let got = parse_config_options(&v);
        assert_eq!(got.len(), 1, "booleans are not kept");
        assert_eq!(got[0].current_name(), Some("GPT-5"));
        assert!(got[0].is("model") && !got[0].is("mode"));
    }

    #[test]
    fn grouped_choices_are_flattened_and_an_unknown_value_shows_as_is() {
        let v = json!([{"id": "m", "category": "model", "type": "select", "currentValue": "x-1",
            "options": [{"group": "g", "name": "Group", "options": [{"value": "a", "name": "A"}]}, {"value": "b"}]}]);
        let got = parse_config_options(&v);
        assert_eq!(
            got[0].choices,
            [("a".into(), "A".into()), ("b".into(), "b".into())]
        );
        assert_eq!(got[0].current_name(), Some("x-1"));
    }

    #[test]
    fn the_older_models_shape_becomes_a_model_option() {
        let r = json!({"models": {"currentModelId": "m2", "availableModels": [{"modelId": "m1", "name": "One"}, {"modelId": "m2", "name": "Two"}]}});
        let o = legacy_models(&r).expect("a model option");
        assert!(o.is("model"));
        assert_eq!(o.current_name(), Some("Two"));
        assert!(legacy_models(&json!({})).is_none());
        assert!(
            o.legacy && !parse_config_options(&json!([{"id": "m", "type": "select"}]))[0].legacy
        );
    }

    #[test]
    fn garbage_is_nothing() {
        assert!(parse_config_options(&json!("x")).is_empty());
        assert!(parse_config_options(&json!([{"type": "select"}])).is_empty());
    }
}
