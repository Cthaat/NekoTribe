#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PageState {
    pub page: u32,
    pub page_size: u32,
    pub start_row: u64,
    pub end_row: u64,
}

impl PageState {
    pub fn from_query(page: Option<&str>, page_size: Option<&str>) -> Self {
        let page = parse_positive(page, 1).clamp(1, 10_000);
        let page_size = parse_positive(page_size, 20).clamp(1, 100);
        let start_row = u64::from(page.saturating_sub(1)) * u64::from(page_size) + 1;
        let end_row = u64::from(page) * u64::from(page_size);

        Self {
            page,
            page_size,
            start_row,
            end_row,
        }
    }
}

fn parse_positive(raw: Option<&str>, fallback: u32) -> u32 {
    raw.and_then(|value| value.trim().parse::<i64>().ok())
        .filter(|value| *value > 0)
        .and_then(|value| u32::try_from(value).ok())
        .unwrap_or(fallback)
}
