pub const QueryOptions = packed struct {
    regex: bool = false,
    case_sensitive: bool = false,
    whole_word: bool = false,
    _padding: u5 = 0,

    pub fn eql(self: QueryOptions, other: QueryOptions) bool {
        return self.regex == other.regex and
            self.case_sensitive == other.case_sensitive and
            self.whole_word == other.whole_word;
    }

    pub fn isDefault(self: QueryOptions) bool {
        return !self.regex and !self.case_sensitive and !self.whole_word;
    }
};
