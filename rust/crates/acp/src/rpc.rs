use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fmt;

/// A request id. Agents use numbers; the keeper hands clients strings (`kp7`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(untagged)]
pub enum Id {
    Num(i64),
    Str(String),
}

/// What an id may arrive as: some agents write a whole number as a float (`2.0`).
#[derive(Deserialize)]
#[serde(untagged)]
enum RawId {
    Int(i64),
    Float(f64),
    Str(String),
}

impl<'de> Deserialize<'de> for Id {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Id, D::Error> {
        match RawId::deserialize(d)? {
            RawId::Int(n) => Ok(Id::Num(n)),
            RawId::Str(s) => Ok(Id::Str(s)),
            // `as` is exact here: the value was checked to be a whole number in range.
            RawId::Float(f) if f.fract() == 0.0 && f.abs() < 9.0e15 => Ok(Id::Num(f as i64)),
            RawId::Float(f) => Err(serde::de::Error::custom(format!(
                "id {f} is not a whole number"
            ))),
        }
    }
}

impl From<i64> for Id {
    fn from(n: i64) -> Self {
        Id::Num(n)
    }
}

impl From<&str> for Id {
    fn from(s: &str) -> Self {
        Id::Str(s.to_string())
    }
}

/// The `error` member of a failed response.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct RpcError {
    /// Some agents leave it out: it then reads as an internal error.
    #[serde(default = "internal_error")]
    pub code: i64,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

fn internal_error() -> i64 {
    -32603
}

impl RpcError {
    #[must_use]
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        RpcError {
            code,
            message: message.into(),
            data: None,
        }
    }
}

impl fmt::Display for RpcError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} ({})", self.message, self.code)
    }
}

impl std::error::Error for RpcError {}

/// One JSON-RPC message.
#[derive(Clone, Debug, PartialEq)]
pub enum Message {
    Request {
        id: Id,
        method: String,
        params: Value,
    },
    Notification {
        method: String,
        params: Value,
    },
    Response {
        id: Id,
        outcome: Result<Value, RpcError>,
    },
}

/// A line that is not a JSON-RPC message.
#[derive(Debug, PartialEq, Eq)]
pub enum ParseError {
    /// Not JSON, or not an object.
    NotJson,
    /// An object with neither a `method` nor an `id` to answer.
    NotRpc,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            ParseError::NotJson => "not a JSON object",
            ParseError::NotRpc => "not a JSON-RPC message",
        })
    }
}

impl std::error::Error for ParseError {}

#[derive(Deserialize)]
struct Raw {
    id: Option<Id>,
    method: Option<String>,
    params: Option<Value>,
    result: Option<Value>,
    error: Option<RpcError>,
}

impl Message {
    /// Parses one line (no trailing newline needed).
    ///
    /// # Errors
    /// [`ParseError::NotJson`] when the line is not a JSON object, and
    /// [`ParseError::NotRpc`] when it is one but names no method and answers no id.
    pub fn parse(line: &str) -> Result<Message, ParseError> {
        let raw: Raw = serde_json::from_str(line).map_err(|_| ParseError::NotJson)?;
        let params = raw.params.unwrap_or(Value::Null);
        match (raw.method, raw.id) {
            (Some(method), Some(id)) => Ok(Message::Request { id, method, params }),
            (Some(method), None) => Ok(Message::Notification { method, params }),
            (None, Some(id)) => {
                let outcome = match raw.error {
                    Some(e) => Err(e),
                    None => Ok(raw.result.unwrap_or(Value::Null)),
                };
                Ok(Message::Response { id, outcome })
            }
            (None, None) => Err(ParseError::NotRpc),
        }
    }

    /// The message as one line, without the trailing newline.
    #[must_use]
    pub fn to_line(&self) -> String {
        let v = match self {
            Message::Request { id, method, params } => {
                json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
            }
            Message::Notification { method, params } => {
                json!({"jsonrpc": "2.0", "method": method, "params": params})
            }
            Message::Response {
                id,
                outcome: Ok(result),
            } => {
                json!({"jsonrpc": "2.0", "id": id, "result": result})
            }
            Message::Response {
                id,
                outcome: Err(e),
            } => {
                json!({"jsonrpc": "2.0", "id": id, "error": e})
            }
        };
        v.to_string()
    }

    #[must_use]
    pub fn request(id: impl Into<Id>, method: &str, params: Value) -> Message {
        Message::Request {
            id: id.into(),
            method: method.to_string(),
            params,
        }
    }

    #[must_use]
    pub fn notification(method: &str, params: Value) -> Message {
        Message::Notification {
            method: method.to_string(),
            params,
        }
    }

    #[must_use]
    pub fn result(id: Id, result: Value) -> Message {
        Message::Response {
            id,
            outcome: Ok(result),
        }
    }

    #[must_use]
    pub fn error(id: Id, error: RpcError) -> Message {
        Message::Response {
            id,
            outcome: Err(error),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_three_shapes_are_told_apart() {
        let req = Message::parse(r#"{"jsonrpc":"2.0","id":"kp1","method":"x","params":{"a":1}}"#);
        assert!(matches!(req, Ok(Message::Request { id: Id::Str(_), .. })));
        let note = Message::parse(r#"{"jsonrpc":"2.0","method":"x"}"#);
        assert!(matches!(note, Ok(Message::Notification { .. })));
        let ok = Message::parse(r#"{"id":3,"result":{"stopReason":"end_turn"}}"#);
        assert!(matches!(
            ok,
            Ok(Message::Response {
                id: Id::Num(3),
                outcome: Ok(_)
            })
        ));
        let err = Message::parse(r#"{"id":3,"error":{"code":-32003,"message":"busy"}}"#);
        assert!(matches!(
            err,
            Ok(Message::Response {
                outcome: Err(RpcError { code: -32003, .. }),
                ..
            })
        ));
    }

    #[test]
    fn garbage_is_rejected_by_kind() {
        assert_eq!(Message::parse("boom"), Err(ParseError::NotJson));
        assert_eq!(Message::parse("[1]"), Err(ParseError::NotJson));
        assert_eq!(Message::parse("{}"), Err(ParseError::NotRpc));
    }

    #[test]
    fn a_message_survives_a_round_trip() {
        let m = Message::request(7, "session/prompt", json!({"sessionId": "s"}));
        assert_eq!(Message::parse(&m.to_line()), Ok(m));
        let e = Message::error(Id::from("kp2"), RpcError::new(-32601, "no"));
        assert_eq!(Message::parse(&e.to_line()), Ok(e));
    }

    #[test]
    fn an_error_without_a_code_and_an_id_written_as_a_float_are_still_responses() {
        let e = Message::parse(r#"{"id":2,"error":{"message":"x"}}"#);
        assert_eq!(
            e,
            Ok(Message::Response {
                id: Id::Num(2),
                outcome: Err(RpcError {
                    code: -32603,
                    message: "x".into(),
                    data: None
                })
            })
        );
        let f = Message::parse(r#"{"id":2.0,"result":{}}"#);
        assert!(
            matches!(f, Ok(Message::Response { id: Id::Num(2), .. })),
            "{f:?}"
        );
        assert_eq!(
            Message::parse(r#"{"id":2.5,"result":{}}"#),
            Err(ParseError::NotJson),
            "a fraction is no id"
        );
        assert_eq!(
            Message::parse(r#"{"id":null,"result":{}}"#),
            Err(ParseError::NotRpc),
            "null names no call"
        );
    }

    #[test]
    fn a_response_without_a_result_is_null_not_an_error() {
        let m = Message::parse(r#"{"id":1}"#);
        assert_eq!(
            m,
            Ok(Message::Response {
                id: Id::Num(1),
                outcome: Ok(Value::Null)
            })
        );
    }
}
