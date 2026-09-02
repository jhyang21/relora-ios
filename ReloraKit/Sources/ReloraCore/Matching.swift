import Foundation

/// One contact suggested as a match for a voice-capture subject. Mirrors
/// `VoiceCaptureMatchCandidate`.
public struct MatchCandidate: Equatable, Sendable {
    public var contactID: String
    public var name: String
    public var score: Double
    public var reason: String

    public init(contactID: String, name: String, score: Double, reason: String) {
        self.contactID = contactID
        self.name = name
        self.score = score
        self.reason = reason
    }
}

/// Mirrors `VoiceCaptureMatchingStatus`.
public enum MatchingStatus: String, Equatable, Sendable {
    case idle
    case matched
    case needsReview = "needs_review"
    case noMatches = "no_matches"
}

/// The contact a review screen should preselect. Mirrors the RN union
/// `string | 'new' | null` (`.new` proposes creating a contact; `.notSet`
/// is RN's `null`, meaning let the person choose).
public enum DefaultSelection: Equatable, Sendable {
    case contactID(String)
    case new
    case notSet
}

/// Mirrors `VoiceCaptureMatchingResult`.
public struct MatchResult: Equatable, Sendable {
    public var candidates: [MatchCandidate]
    public var defaultSelection: DefaultSelection
    public var status: MatchingStatus

    public init(candidates: [MatchCandidate], defaultSelection: DefaultSelection, status: MatchingStatus) {
        self.candidates = candidates
        self.defaultSelection = defaultSelection
        self.status = status
    }
}

/// Fuzzy contact matching for the voice-capture review flow. Ports
/// apps/mobile/src/features/voice/voiceCaptureMatching.ts in full — only
/// `matchVoiceCaptureContacts` and its result types are exported there, so
/// only those are public here; every scoring helper below is a faithful,
/// private, line-by-line port whose job is to reproduce RN's candidate
/// ordering exactly, not to offer a general-purpose API.
public enum ContactMatching {
    // RN: MAX_CANDIDATES
    private static let maxCandidates = 4
    // RN: MINIMUM_CANDIDATE_SCORE
    private static let minimumCandidateScore = 45.0
    // RN: HIGH_CONFIDENCE_MATCH_SCORE
    private static let highConfidenceMatchScore = 60.0
    // RN: HIGH_CONFIDENCE_MARGIN
    private static let highConfidenceMargin = 12.0
    // RN: DIRECT_NAME_MATCH_THRESHOLD
    private static let directNameMatchThreshold = 0.74
    // RN: EFFECTIVE_TIE_DELTA
    private static let effectiveTieDelta = 2.0
    // RN: INITIAL_CONTACT_BONUS
    private static let initialContactBonus = 95.0
    // RN: SUBJECT_MATCH_WEIGHT
    private static let subjectMatchWeight = 70.0
    // RN: TRANSCRIPT_SUPPORT_WEIGHT
    private static let transcriptSupportWeight = 18.0
    // RN: MAX_TRANSCRIPT_WINDOW_TOKENS
    private static let maxTranscriptWindowTokens = 4

    private struct PreparedToken {
        let strict: String
        let loose: String
        let phonetic: String
        let weight: Double
    }

    private struct PreparedName {
        let strict: String
        let tokens: [PreparedToken]
    }

    private struct AlignmentPair {
        let queryIndex: Int
        let contactIndex: Int
        let similarity: Double
        let pairWeight: Double
    }

    private struct AlignmentResult {
        let pairs: [AlignmentPair]
    }

    private struct AlignmentMemoKey: Hashable {
        let queryIndex: Int
        let usedMask: Int
    }

    private struct ScoredCandidate {
        let candidate: MatchCandidate
        let recency: Double
        let hasInitialContext: Bool
        let subjectSimilarity: Double
        let transcriptSupport: Double
    }

    private static func clamp(_ value: Double, _ minimum: Double = 0, _ maximum: Double = 1) -> Double {
        Swift.min(maximum, Swift.max(minimum, value))
    }

    /// NFKD-decomposes, strips combining diacritical marks (U+0300–U+036F),
    /// lowercases, and collapses every run of non `[a-z0-9]` characters into
    /// a single space, trimmed. Every downstream strict/loose/phonetic
    /// string is pure ASCII, so `Character`-based counting and indexing
    /// below is equivalent to JS's UTF-16-code-unit-based `.length`.
    private static func normalizeStrictName(_ value: String) -> String {
        let decomposed = value.decomposedStringWithCompatibilityMapping
        var stripped = String.UnicodeScalarView()
        for scalar in decomposed.unicodeScalars where !(0x0300...0x036F).contains(scalar.value) {
            stripped.append(scalar)
        }
        let lowered = String(stripped).lowercased()
        let spaced = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        return spaced.trimmingCharacters(in: .whitespaces)
    }

    /// Collapses consecutive duplicate characters (e.g. "mm" -> "m"), then
    /// maps every vowel-ish character to 'a' — a cheap phonetic fuzzer for
    /// misheard/misspelled names ("Muhamed" vs "Mohammed").
    private static func normalizeLooseToken(_ value: String) -> String {
        var collapsed = ""
        var previous: Character?
        for character in value where character != previous {
            collapsed.append(character)
            previous = character
        }

        var mapped = ""
        for character in collapsed {
            mapped.append("aeiouy".contains(character) ? "a" : character)
        }
        return mapped
    }

    private static func getTokenWeight(_ value: String) -> Double {
        if value.count <= 2 { return 0.45 }
        if value.count == 3 { return 0.75 }
        return 1
    }

    /// A Soundex-like phonetic code: first character verbatim, then coded
    /// consonant digits with zeros dropped and adjacent repeats of the same
    /// digit collapsed (comparing each character's own digit against the
    /// *previous character's* digit, not the previously-kept digit).
    private static func computePhoneticCode(_ value: String) -> String {
        guard let first = value.first else { return "" }

        var encoded = ""
        var previousDigit: Character?
        for character in value.dropFirst() {
            let digit: Character
            if "bfpv".contains(character) {
                digit = "1"
            } else if "cgjkqsxz".contains(character) {
                digit = "2"
            } else if "dt".contains(character) {
                digit = "3"
            } else if character == "l" {
                digit = "4"
            } else if "mn".contains(character) {
                digit = "5"
            } else if character == "r" {
                digit = "6"
            } else {
                digit = "0"
            }

            if digit != "0", digit != previousDigit {
                encoded.append(digit)
            }
            previousDigit = digit
        }

        return "\(first)\(encoded)"
    }

    private static func tokenizeName(_ value: String) -> [PreparedToken] {
        let strict = normalizeStrictName(value)
        if strict.isEmpty { return [] }

        return strict
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 }
            .map { token in
                PreparedToken(
                    strict: token,
                    loose: normalizeLooseToken(token),
                    phonetic: computePhoneticCode(token),
                    weight: getTokenWeight(token)
                )
            }
    }

    private static func prepareName(_ value: String) -> PreparedName {
        PreparedName(strict: normalizeStrictName(value), tokens: tokenizeName(value))
    }

    /// Damerau-Levenshtein distance restricted to adjacent transpositions
    /// (the "optimal string alignment" variant, not true Damerau-Levenshtein
    /// — matches the RN implementation exactly, including its bounds).
    private static func computeEditDistance(_ left: String, _ right: String) -> Int {
        if left == right { return 0 }

        let leftChars = Array(left)
        let rightChars = Array(right)
        if leftChars.isEmpty { return rightChars.count }
        if rightChars.isEmpty { return leftChars.count }

        let rows = leftChars.count + 1
        let columns = rightChars.count + 1
        var matrix = Array(repeating: Array(repeating: 0, count: columns), count: rows)

        for row in 0..<rows { matrix[row][0] = row }
        for column in 0..<columns { matrix[0][column] = column }

        for row in 1..<rows {
            for column in 1..<columns {
                let substitutionCost = leftChars[row - 1] == rightChars[column - 1] ? 0 : 1
                matrix[row][column] = Swift.min(
                    matrix[row - 1][column] + 1,
                    matrix[row][column - 1] + 1,
                    matrix[row - 1][column - 1] + substitutionCost
                )

                if row > 1, column > 1,
                   leftChars[row - 1] == rightChars[column - 2],
                   leftChars[row - 2] == rightChars[column - 1] {
                    matrix[row][column] = Swift.min(matrix[row][column], matrix[row - 2][column - 2] + 1)
                }
            }
        }

        return matrix[leftChars.count][rightChars.count]
    }

    private static func computeEditSimilarity(_ left: String, _ right: String) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let maximumLength = Swift.max(left.count, right.count)
        if maximumLength == 0 { return 0 }
        return clamp(1 - Double(computeEditDistance(left, right)) / Double(maximumLength))
    }

    /// Jaccard similarity over character bigrams.
    private static func computeBigramSimilarity(_ left: String, _ right: String) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }

        func toBigrams(_ value: String) -> Set<String> {
            let chars = Array(value)
            guard chars.count >= 2 else { return [value] }
            var bigrams: Set<String> = []
            for index in 0..<(chars.count - 1) {
                bigrams.insert(String(chars[index...index + 1]))
            }
            return bigrams
        }

        let leftBigrams = toBigrams(left)
        let rightBigrams = toBigrams(right)
        let unionCount = leftBigrams.union(rightBigrams).count
        guard unionCount > 0 else { return 0 }
        return Double(leftBigrams.intersection(rightBigrams).count) / Double(unionCount)
    }

    private static func getCommonPrefixLength(_ left: String, _ right: String) -> Int {
        let leftChars = Array(left)
        let rightChars = Array(right)
        let limit = Swift.min(leftChars.count, rightChars.count)
        var index = 0
        while index < limit, leftChars[index] == rightChars[index] {
            index += 1
        }
        return index
    }

    private static func getMinimumPairSimilarity(_ left: PreparedToken, _ right: PreparedToken) -> Double {
        let minimumLength = Swift.min(left.strict.count, right.strict.count)
        if minimumLength <= 2 { return 1 }
        if minimumLength == 3 { return 0.72 }
        return 0.5
    }

    /// Weighted blend of strict/loose edit similarity and bigram overlap,
    /// adjusted by relative length, first-letter agreement, a phonetic-code
    /// match bonus, a shared-prefix bonus, and a hard cap for very short
    /// tokens so two unrelated two-letter tokens can't score high by luck.
    private static func computeTokenSimilarity(_ left: PreparedToken, _ right: PreparedToken) -> Double {
        if left.strict == right.strict { return 1 }

        let strictEditSimilarity = computeEditSimilarity(left.strict, right.strict)
        let looseEditSimilarity = computeEditSimilarity(left.loose, right.loose)
        let bigramSimilarity = computeBigramSimilarity(left.strict, right.strict)
        let lengthRatio = Double(Swift.min(left.strict.count, right.strict.count))
            / Double(Swift.max(left.strict.count, right.strict.count))
        let firstLetterFactor: Double = left.strict.first == right.strict.first ? 1 : 0.82

        var similarity = strictEditSimilarity * 0.55 + looseEditSimilarity * 0.25 + bigramSimilarity * 0.2
        similarity *= 0.7 + 0.3 * lengthRatio
        similarity *= firstLetterFactor

        if !left.phonetic.isEmpty, left.phonetic == right.phonetic, strictEditSimilarity >= 0.55 {
            similarity += 0.06
        }

        let commonPrefixLength = getCommonPrefixLength(left.strict, right.strict)
        if left.strict.count >= 4, right.strict.count >= 4, commonPrefixLength >= 3 {
            let maxLength = Double(Swift.max(left.strict.count, right.strict.count))
            similarity += Swift.min(0.04, Double(commonPrefixLength) / maxLength / 4)
        }

        if Swift.min(left.strict.count, right.strict.count) <= 2 {
            similarity = Swift.min(similarity, 0.34)
        }

        return clamp(similarity)
    }

    /// Bitmask-memoized recursive search for the query-token-to-contact-token
    /// assignment that maximizes total weighted similarity, subject to each
    /// pair clearing `getMinimumPairSimilarity`. Mirrors `alignTokenSets`.
    private static func alignTokenSets(_ queryTokens: [PreparedToken], _ contactTokens: [PreparedToken]) -> AlignmentResult {
        var memo: [AlignmentMemoKey: AlignmentResult] = [:]

        func score(_ pairs: [AlignmentPair]) -> Double {
            pairs.reduce(0) { $0 + $1.similarity * $1.pairWeight }
        }

        func visit(_ queryIndex: Int, _ usedMask: Int) -> AlignmentResult {
            let key = AlignmentMemoKey(queryIndex: queryIndex, usedMask: usedMask)
            if let cached = memo[key] {
                return cached
            }

            if queryIndex >= queryTokens.count {
                let result = AlignmentResult(pairs: [])
                memo[key] = result
                return result
            }

            var bestResult = visit(queryIndex + 1, usedMask)
            var bestScore = score(bestResult.pairs)

            for contactIndex in 0..<contactTokens.count {
                let bit = 1 << contactIndex
                if usedMask & bit != 0 { continue }

                let queryToken = queryTokens[queryIndex]
                let contactToken = contactTokens[contactIndex]
                let similarity = computeTokenSimilarity(queryToken, contactToken)

                if similarity < getMinimumPairSimilarity(queryToken, contactToken) {
                    continue
                }

                let remainder = visit(queryIndex + 1, usedMask | bit)
                let pairWeight = (queryToken.weight + contactToken.weight) / 2
                let totalScore = similarity * pairWeight + score(remainder.pairs)

                if totalScore > bestScore {
                    bestScore = totalScore
                    var pairs = [AlignmentPair(
                        queryIndex: queryIndex,
                        contactIndex: contactIndex,
                        similarity: similarity,
                        pairWeight: pairWeight
                    )]
                    pairs.append(contentsOf: remainder.pairs)
                    bestResult = AlignmentResult(pairs: pairs)
                }
            }

            memo[key] = bestResult
            return bestResult
        }

        return visit(0, 0)
    }

    /// Harmonic-mean-like blend of how much of the query's and how much of
    /// the contact's token weight ended up matched.
    private static func computeCoverageFactor(
        matchedQueryWeight: Double,
        totalQueryWeight: Double,
        matchedContactWeight: Double,
        totalContactWeight: Double
    ) -> Double {
        guard totalQueryWeight > 0, totalContactWeight > 0 else { return 0 }
        let queryCoverage = matchedQueryWeight / totalQueryWeight
        let contactCoverage = matchedContactWeight / totalContactWeight
        guard queryCoverage > 0, contactCoverage > 0 else { return 0 }
        return (2 * queryCoverage * contactCoverage) / (queryCoverage + contactCoverage)
    }

    /// Penalizes matches whose token order is scrambled relative to the
    /// contact's name, via a pair-inversion count clamped to [0.92, 1].
    private static func computeOrderFactor(_ pairs: [AlignmentPair]) -> Double {
        if pairs.count <= 1 { return 1 }

        var inversions = 0
        for leftIndex in 0..<pairs.count {
            for rightIndex in (leftIndex + 1)..<pairs.count where pairs[leftIndex].contactIndex > pairs[rightIndex].contactIndex {
                inversions += 1
            }
        }

        let maximumInversions = Double(pairs.count * (pairs.count - 1)) / 2
        if maximumInversions == 0 { return 1 }

        return clamp(1 - 0.08 * (Double(inversions) / maximumInversions), 0.92, 1)
    }

    /// alignmentQuality x coverageFactor x orderFactor. Mirrors
    /// `computeNameSimilarity`.
    private static func computeNameSimilarity(_ query: PreparedName, _ contact: PreparedName) -> Double {
        guard !query.tokens.isEmpty, !contact.tokens.isEmpty else { return 0 }

        let alignment = alignTokenSets(query.tokens, contact.tokens)
        guard !alignment.pairs.isEmpty else { return 0 }

        let totalQueryWeight = query.tokens.reduce(0) { $0 + $1.weight }
        let totalContactWeight = contact.tokens.reduce(0) { $0 + $1.weight }

        var matchedQueryIndices: Set<Int> = []
        var matchedContactIndices: Set<Int> = []
        var weightedSimilarityTotal = 0.0
        var totalPairWeight = 0.0

        for pair in alignment.pairs {
            weightedSimilarityTotal += pair.similarity * pair.pairWeight
            totalPairWeight += pair.pairWeight
            matchedQueryIndices.insert(pair.queryIndex)
            matchedContactIndices.insert(pair.contactIndex)
        }

        let matchedQueryWeight = matchedQueryIndices.reduce(0) { $0 + query.tokens[$1].weight }
        let matchedContactWeight = matchedContactIndices.reduce(0) { $0 + contact.tokens[$1].weight }

        let coverageFactor = computeCoverageFactor(
            matchedQueryWeight: matchedQueryWeight,
            totalQueryWeight: totalQueryWeight,
            matchedContactWeight: matchedContactWeight,
            totalContactWeight: totalContactWeight
        )
        let orderFactor = computeOrderFactor(alignment.pairs)
        let alignmentQuality = totalPairWeight > 0 ? weightedSimilarityTotal / totalPairWeight : 0

        return clamp(alignmentQuality * coverageFactor * orderFactor)
    }

    /// Slides windows of up to `maxTranscriptWindowTokens` transcript tokens
    /// and keeps the best `computeNameSimilarity` against the contact's
    /// name, floored to 0 below a 0.55 confidence bar. Mirrors
    /// `computeTranscriptSupport`.
    private static func computeTranscriptSupport(_ transcript: PreparedName, _ contact: PreparedName) -> Double {
        guard !transcript.tokens.isEmpty, !contact.tokens.isEmpty else { return 0 }

        let maximumWindowLength = Swift.min(maxTranscriptWindowTokens, Swift.max(1, contact.tokens.count + 1))
        var bestSimilarity = 0.0

        for start in 0..<transcript.tokens.count {
            for length in 1...maximumWindowLength {
                let end = Swift.min(start + length, transcript.tokens.count)
                guard end > start else { continue }
                let windowTokens = Array(transcript.tokens[start..<end])

                let similarity = computeNameSimilarity(
                    PreparedName(strict: windowTokens.map(\.strict).joined(separator: " "), tokens: windowTokens),
                    contact
                )
                if similarity > bestSimilarity {
                    bestSimilarity = similarity
                }
            }
        }

        return bestSimilarity >= 0.55 ? bestSimilarity : 0
    }

    /// Falls back from `lastInteractionAt` to `updatedAt`; unparsable
    /// timestamps rank as epoch zero rather than excluding the candidate.
    /// Note: unlike JS's permissive `Date.parse`, `ReloraTimestamp.parse`
    /// only accepts the app's own wire format — sufficient here since
    /// `lastInteractionAt`/`updatedAt` are always written by
    /// `ReloraTimestamp`, never by an external source.
    private static func getRecencyValue(_ contact: Contact) -> Double {
        let timestamp = contact.lastInteractionAt ?? contact.updatedAt
        return ReloraTimestamp.parse(timestamp)?.timeIntervalSince1970 ?? 0
    }

    private static func roundScore(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// Produces the exact user-facing reason strings RN shows next to a
    /// candidate. Preserve verbatim — copy review depends on these.
    private static func buildReason(
        hasInitialContext: Bool,
        subjectSimilarity: Double,
        transcriptSupport: Double
    ) -> String {
        if hasInitialContext, subjectSimilarity >= directNameMatchThreshold {
            return "Opened from this contact and matches the subject guess"
        }
        if hasInitialContext {
            return "Opened from this contact"
        }
        if subjectSimilarity >= 0.86 {
            return transcriptSupport >= 0.6
                ? "Strong subject-name match, supported by transcript"
                : "Strong subject-name match"
        }
        if subjectSimilarity >= directNameMatchThreshold {
            return transcriptSupport >= 0.6
                ? "Close subject-name match, supported by transcript"
                : "Close subject-name match"
        }
        if transcriptSupport >= 0.82 {
            return "Transcript supports this name"
        }
        if transcriptSupport >= 0.65 {
            return "Possible transcript support"
        }
        return "Possible subject-name match"
    }

    private static func scoreContact(
        contact: Contact,
        preparedSubjectGuess: PreparedName,
        preparedTranscript: PreparedName,
        initialContactID: String?
    ) -> ScoredCandidate? {
        let preparedContact = prepareName(contact.name)
        guard !preparedContact.tokens.isEmpty else { return nil }

        let hasInitialContext = contact.id == initialContactID
        let subjectSimilarity = preparedSubjectGuess.tokens.isEmpty
            ? 0
            : computeNameSimilarity(preparedSubjectGuess, preparedContact)
        let transcriptSupport = computeTranscriptSupport(preparedTranscript, preparedContact)
        let score = (hasInitialContext ? initialContactBonus : 0)
            + subjectSimilarity * subjectMatchWeight
            + transcriptSupport * transcriptSupportWeight

        guard score >= minimumCandidateScore else { return nil }

        return ScoredCandidate(
            candidate: MatchCandidate(
                contactID: contact.id,
                name: contact.name,
                score: roundScore(score),
                reason: buildReason(
                    hasInitialContext: hasInitialContext,
                    subjectSimilarity: subjectSimilarity,
                    transcriptSupport: transcriptSupport
                )
            ),
            recency: getRecencyValue(contact),
            hasInitialContext: hasInitialContext,
            subjectSimilarity: subjectSimilarity,
            transcriptSupport: transcriptSupport
        )
    }

    /// The JS-comparator-equivalent ordering value: negative means `left`
    /// sorts before `right`. Tie-break order: score (beyond
    /// `effectiveTieDelta`), then recency, then leftover score delta, then
    /// name, then id.
    ///
    /// Note: RN's final tiebreak is `String.prototype.localeCompare`, which
    /// is locale- and Unicode-collation-aware; `String.compare` here orders
    /// by literal Unicode scalar value. The two agree for the plain ASCII
    /// names this module is exercised against, but could diverge on names
    /// mixing scripts or accented characters that collate differently from
    /// their raw code points.
    private static func compareValue(_ left: ScoredCandidate, _ right: ScoredCandidate) -> Double {
        let scoreDelta = right.candidate.score - left.candidate.score
        if abs(scoreDelta) > effectiveTieDelta {
            return scoreDelta
        }

        let recencyDelta = right.recency - left.recency
        if recencyDelta != 0 {
            return recencyDelta
        }

        if scoreDelta != 0 {
            return scoreDelta
        }

        let nameCompare = left.candidate.name.compare(right.candidate.name)
        if nameCompare != .orderedSame {
            return nameCompare == .orderedAscending ? -1 : 1
        }

        let idCompare = left.candidate.contactID.compare(right.candidate.contactID)
        switch idCompare {
        case .orderedAscending: return -1
        case .orderedDescending: return 1
        case .orderedSame: return 0
        }
    }

    private static func isOrderedBefore(_ left: ScoredCandidate, _ right: ScoredCandidate) -> Bool {
        compareValue(left, right) < 0
    }

    /// A candidate opened "from this contact" is passed over when it lacks
    /// a strong direct name match but a runner-up has one — the initial
    /// context alone isn't trusted to override clear name evidence
    /// elsewhere. Mirrors `hasInitialConflict`.
    private static func hasInitialConflict(top: ScoredCandidate, runnerUp: ScoredCandidate?) -> Bool {
        guard top.hasInitialContext, let runnerUp = runnerUp else { return false }
        if top.subjectSimilarity >= directNameMatchThreshold { return false }
        return runnerUp.subjectSimilarity >= directNameMatchThreshold
    }

    /// Scores contacts against the extracted subject name and transcript to
    /// suggest the best match. Mirrors `matchVoiceCaptureContacts`.
    ///
    /// - Parameter initialContactID: An empty string is treated the same as
    ///   `nil` for the `.idle` short-circuit below, matching JS's
    ///   `!initialContactId` truthiness check on `''`; the per-contact
    ///   `contact.id === initialContactId` equality elsewhere is unaffected,
    ///   since no contact id is ever empty.
    public static func matchVoiceCaptureContacts(
        contacts: [Contact],
        transcript: String,
        subjectNameGuess: String? = nil,
        initialContactID: String? = nil
    ) -> MatchResult {
        let preparedSubjectGuess = prepareName(subjectNameGuess ?? "")
        let preparedTranscript = prepareName(transcript)
        let hasInitialContactID = !(initialContactID ?? "").isEmpty

        if preparedSubjectGuess.tokens.isEmpty, preparedTranscript.tokens.isEmpty, !hasInitialContactID {
            return MatchResult(candidates: [], defaultSelection: .notSet, status: .idle)
        }

        let scoredCandidates = Array(
            contacts
                .compactMap { contact in
                    scoreContact(
                        contact: contact,
                        preparedSubjectGuess: preparedSubjectGuess,
                        preparedTranscript: preparedTranscript,
                        initialContactID: initialContactID
                    )
                }
                .sorted(by: isOrderedBefore)
                .prefix(maxCandidates)
        )

        guard let topCandidate = scoredCandidates.first else {
            return MatchResult(candidates: [], defaultSelection: .new, status: .noMatches)
        }

        let runnerUpCandidate = scoredCandidates.count > 1 ? scoredCandidates[1] : nil
        let scoreGap = runnerUpCandidate.map { abs(topCandidate.candidate.score - $0.candidate.score) }
            ?? topCandidate.candidate.score
        let hasStrongDirectSignal = topCandidate.hasInitialContext
            || topCandidate.subjectSimilarity >= directNameMatchThreshold
        let isMatched = topCandidate.candidate.score >= highConfidenceMatchScore
            && scoreGap >= highConfidenceMargin
            && hasStrongDirectSignal
            && !hasInitialConflict(top: topCandidate, runnerUp: runnerUpCandidate)

        return MatchResult(
            candidates: scoredCandidates.map(\.candidate),
            defaultSelection: isMatched ? .contactID(topCandidate.candidate.contactID) : .notSet,
            status: isMatched ? .matched : .needsReview
        )
    }
}
