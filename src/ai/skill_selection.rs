//! Controlled internal skill selection; callers supply real current authorization.
use std::collections::HashSet;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Unavailable,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scope {
    pub actor_id: i64,
    pub purpose: String,
    pub group_id: Option<i64>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Selection {
    pub scope: Scope,
    pub id: String,
    pub version: u32,
    pub selection: String,
    pub tools: Vec<String>,
}
pub struct Registry {
    enabled: HashSet<String>,
}
#[derive(serde::Serialize)]
pub struct UserAvailability {
    pub knowledge: bool,
    pub writing: bool,
    pub group: bool,
    pub moderation: bool,
}

const SKILL_VERSION: u32 = 1;

#[derive(serde::Serialize)]
pub(crate) struct SkillAvailability {
    pub(crate) id: &'static str,
    pub(crate) purpose: &'static str,
    pub(crate) version: u32,
    pub(crate) enabled: bool,
    explicit_selection: bool,
}

impl UserAvailability {
    pub(crate) fn skills(&self) -> [SkillAvailability; 4] {
        [
            ("knowledge", self.knowledge),
            ("writing", self.writing),
            ("group", self.group),
            ("moderation", self.moderation),
        ]
        .map(|(purpose, enabled)| {
            let (id, _) = definition(purpose).expect("released skill purpose");
            SkillAvailability {
                id,
                purpose,
                version: SKILL_VERSION,
                enabled,
                explicit_selection: true,
            }
        })
    }
}

fn definition(purpose: &str) -> Option<(&'static str, &'static [&'static str])> {
    match purpose {
        "knowledge" => Some(("knowledge-answer", &["public_search"])),
        "writing" => Some(("writing-draft", &[])),
        "group" => Some(("group-brief", &["public_search", "public_statistics"])),
        "moderation" => Some(("moderation-advice", &["public_search"])),
        _ => None,
    }
}
impl Registry {
    pub(crate) fn enabled_ids(&self) -> Vec<String> {
        let mut ids: Vec<_> = self.enabled.iter().cloned().collect();
        ids.sort_unstable();
        ids
    }

    pub fn user_availability(&self) -> UserAvailability {
        UserAvailability {
            knowledge: self.enabled.contains("knowledge-answer"),
            writing: self.enabled.contains("writing-draft"),
            group: self.enabled.contains("group-brief"),
            moderation: self.enabled.contains("moderation-advice"),
        }
    }
    pub fn new(enabled: &[String]) -> Result<Self, Error> {
        let mut selected = HashSet::new();
        for id in enabled {
            if !["knowledge", "writing", "group", "moderation"]
                .iter()
                .any(|p| definition(p).is_some_and(|(known, _)| known == id))
                || !selected.insert(id.clone())
            {
                return Err(Error::Unavailable);
            }
        }
        Ok(Self { enabled: selected })
    }
    /// A successful selection is a snapshot, never a durable authorization grant.
    pub fn select(
        &self,
        scope: &Scope,
        skill_id: Option<&str>,
        authorize: impl FnOnce(&Scope) -> Result<(), Error>,
    ) -> Result<Selection, Error> {
        let (id, tools) = definition(&scope.purpose).ok_or(Error::Unavailable)?;
        if !(1..=9_007_199_254_740_991).contains(&scope.actor_id)
            || (scope.purpose == "group"
                && !scope
                    .group_id
                    .is_some_and(|id| (1..=999_999_999_999_999).contains(&id)))
            || (scope.purpose != "group" && scope.group_id.is_some())
            || skill_id.is_some_and(|selected| selected != id)
            || !self.enabled.contains(id)
        {
            return Err(Error::Unavailable);
        }
        authorize(scope).map_err(|_| Error::Unavailable)?;
        Ok(Selection {
            scope: scope.clone(),
            id: id.into(),
            version: SKILL_VERSION,
            selection: if skill_id.is_some() {
                "explicit"
            } else {
                "purpose-default"
            }
            .into(),
            tools: tools.iter().map(|v| (*v).into()).collect(),
        })
    }
}
