/*
 * Copyright (C) 2026  scidCommunity contributors.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "treeindex.h"
#include "misc.h"
#include "position.h"
#include "scidbase.h"
#include "stored.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <map>
#include <random>
#include <system_error>
#include <unordered_map>

namespace {

constexpr char kMagic[8] = {'S', 'C', 'I', 'D', 'T', 'R', 'E', 'E'};
constexpr uint32_t kVersion = 2; // bump if the key or the record layout change
constexpr unsigned kMaxPlyLimit = 255;
constexpr unsigned kDepth = TreeIndex::kMaxDepth;

// shortcut: the file is written in the native byte order; all the platforms
// Scid runs on are little-endian. Add a byte swap if that ever changes.
struct Header {
	char magic[8];
	uint32_t version;
	uint32_t threshold;
	uint32_t maxPly;
	uint32_t numGames;
	uint64_t fingerprint; // sizes and dates of the database files
	uint64_t numRecords;
	uint32_t deepThreshold;
	uint32_t reserved1;
	uint64_t numDeepRecords; // written after the Records
	uint32_t reserved2[2];
};
static_assert(sizeof(Header) == 64);

// The fields of TreeNode, for one (position, move).
struct Record {
	uint64_t key;
	uint32_t move; // FullMove, with the SAN info (check, ambiguity)
	uint32_t freq[NUM_RESULT_TYPES];
	uint32_t eloCount;
	uint32_t yearCount;
	uint32_t lengthCount;
	uint64_t eloWhiteSum;
	uint64_t eloBlackSum;
	uint64_t yearSum;
	uint64_t lengthSum;
};
static_assert(sizeof(Record) == 72 && NUM_RESULT_TYPES == 4);

// The stats of one sequence of up to kDepth plies played from a position.
struct DeepRecord {
	uint64_t key;
	uint32_t moves[kDepth]; // FullMove; 0 after the last move of a game
	uint32_t freq[NUM_RESULT_TYPES];
	uint32_t eloCount;
	uint32_t yearCount;
	uint32_t lengthCount;
	uint32_t unused; // no padding bytes in the file
	uint64_t eloWhiteSum;
	uint64_t eloBlackSum;
	uint64_t yearSum;
	uint64_t lengthSum;
};
static_assert(sizeof(DeepRecord) == 88);

// Same accumulation as TreeNode::add() and getTreeStat().
template <typename R> void addGame(R& r, const IndexEntry* ie) {
	r.freq[0]++;
	if (auto result = ie->GetResult(); result != RESULT_None)
		r.freq[result]++;
	const int eloW = ie->GetWhiteElo(), eloB = ie->GetBlackElo();
	if (eloW > 0 && eloB > 0) {
		++r.eloCount;
		r.eloWhiteSum += eloW;
		r.eloBlackSum += eloB;
	}
	if (unsigned year = ie->GetYear(); year > 0) {
		r.yearSum += year;
		++r.yearCount;
	}
	r.lengthSum += (ie->GetNumHalfMoves() + 1) / 2;
	++r.lengthCount;
}

template <typename R> void addStats(TreeNode& node, const R& r) {
	for (int i = 0; i < NUM_RESULT_TYPES; ++i)
		node.freq[i] += r.freq[i];
	node.eloCount += r.eloCount;
	node.eloWhiteSum += r.eloWhiteSum;
	node.eloBlackSum += r.eloBlackSum;
	node.yearCount += r.yearCount;
	node.yearSum += r.yearSum;
	node.lengthCount += r.lengthCount;
	node.lengthSum += r.lengthSum;
}

template <typename R> R recordAt(const char* records, size_t i) {
	R r;
	std::memcpy(&r, records + i * sizeof(R), sizeof r);
	return r;
}

// @returns the range of the records of @e key (each record starts with it).
template <typename R>
std::pair<size_t, size_t> keyRange(const char* records, size_t n, uint64_t key) {
	auto keyAt = [&](size_t i) {
		uint64_t k;
		std::memcpy(&k, records + i * sizeof(R), sizeof k);
		return k;
	};
	size_t lo = 0, hi = n;
	while (lo < hi) {
		const size_t mid = lo + (hi - lo) / 2;
		if (keyAt(mid) < key)
			lo = mid + 1;
		else
			hi = mid;
	}
	size_t end = lo;
	while (end < n && keyAt(end) == key)
		++end;
	return {lo, end};
}

// Keeps the records of the keys whose records count at least @e threshold
// games in all (records sorted by key).
template <typename R>
void keepFrequent(std::vector<R>& records, uint64_t threshold) {
	auto out = records.begin();
	for (auto it = records.begin(); it != records.end();) {
		auto end = std::find_if(it, records.end(),
		                        [&](auto const& r) { return r.key != it->key; });
		uint64_t games = 0;
		for (auto e = it; e != end; ++e)
			games += e->freq[0];
		if (games >= threshold)
			out = std::copy(it, end, out);
		it = end;
	}
	records.erase(out, records.end());
}

struct Zobrist {
	uint64_t piece[2][8][64];
	uint64_t blackToMove;

	Zobrist() {
		std::mt19937_64 rng(20261113); // fixed: the keys are stored in files
		for (auto& color : piece)
			for (auto& type : color)
				for (auto& sq : type)
					sq = rng();
		blackToMove = rng();
	}
};

const Zobrist& zobrist() {
	static const Zobrist z;
	return z;
}

// Updates the key @e h for @e move played by @e color.
// @returns false for a null move (the tree does not follow them).
bool applyMove(uint64_t& h, colorT color, FullMove move) {
	const auto& z = zobrist().piece[color];
	const squareT from = move.getFrom(), to = move.getTo();
	if (from == to)
		return false;
	if (move.isCastle()) { // from = king square, to = rook square
		const bool kingSide = to > from;
		const squareT kingTo = square_Relative(color, kingSide ? G1 : C1);
		const squareT rookTo = square_Relative(color, kingSide ? F1 : D1);
		h ^= z[KING][from] ^ z[KING][kingTo] ^ z[ROOK][to] ^ z[ROOK][rookTo];
	} else {
		const pieceT pt = move.getPiece();
		h ^= z[pt][from];
		if (const pieceT captured = move.getCaptured()) {
			squareT sq = to;
			if (move.isEnpassant())
				sq = (color == WHITE) ? to - 8 : to + 8;
			h ^= zobrist().piece[color_Flip(color)][captured][sq];
		}
		h ^= z[move.isPromo() ? move.getPromo() : pt][to];
	}
	h ^= zobrist().blackToMove;
	return true;
}

uint64_t fingerprint(const scidBaseT& base) {
	uint64_t h = 0x9E3779B97F4A7C15ULL;
	auto mix = [&](uint64_t v) {
		h ^= v + 0x9E3779B97F4A7C15ULL + (h << 6) + (h >> 2);
	};
	for (auto const& name : base.getFileNames()) {
		const auto path = pathFromUtf8(name);
		std::error_code ec;
		mix(std::filesystem::file_size(path, ec));
		mix(static_cast<uint64_t>(
		    std::filesystem::last_write_time(path, ec).time_since_epoch().count()));
	}
	return h;
}

// Calls fn(parentKey, next, nNext) for the main-line positions in the first
// maxPly plies of a game, once per position: like the tree, a game counts for
// the first time it reaches a position. next[0, nNext) are the moves played
// from it, up to kDepth (fewer when the game ends).
template <typename Fn>
void forEachMove(const scidBaseT& base, const IndexEntry* ie, unsigned maxPly,
                 uint64_t stdStartKey, Fn fn) {
	uint64_t key = stdStartKey;
	colorT color = WHITE;
	if (ie->GetStartFlag()) {
		auto data = base.getGame(*ie);
		if (data.decodeTags([](auto, auto) {}) != OK)
			return;
		auto [err, fen] = data.decodeStartBoard();
		Position start;
		if (err != OK || !fen || start.ReadFromFEN(fen) != OK)
			return;
		key = TreeIndex::positionKey(start);
		color = start.GetToMove();
	}
	FullMove moves[kMaxPlyLimit + kDepth];
	const unsigned wanted = maxPly + kDepth - 1;
	unsigned nMoves = 0;
	base.getGame(ie).mainLineSAN([&](FullMove move) {
		moves[nMoves++] = move;
		return nMoves < wanted;
	});
	// The tree search and getTreeStat() read the opening moves from the
	// stored line of the index entry, without decoding the game: do the same
	// when the game data cannot be decoded that far.
	if (!ie->GetStartFlag()) {
		for (; nMoves < wanted; ++nMoves) {
			moves[nMoves] = StoredLine::getMove(ie->GetStoredLineCode(), nMoves);
			if (!moves[nMoves])
				break;
		}
	}

	uint64_t seen[kMaxPlyLimit];
	unsigned nSeen = 0;
	for (unsigned i = 0; i < nMoves && i < maxPly; ++i) {
		const uint64_t parent = key;
		if (!applyMove(key, color, moves[i]))
			return;
		color = color_Flip(color);
		if (std::find(seen, seen + nSeen, parent) == seen + nSeen) {
			seen[nSeen++] = parent;
			fn(parent, moves + i, std::min(nMoves - i, kDepth));
		}
	}
}

uint32_t rawMove(FullMove move) {
	uint32_t raw;
	static_assert(sizeof(move) == sizeof(raw));
	std::memcpy(&raw, &move, sizeof(raw));
	return raw;
}

} // namespace

uint64_t TreeIndex::positionKey(const Position& pos) {
	const auto& z = zobrist();
	uint64_t h = 0;
	for (squareT sq = 0; sq < 64; ++sq) {
		const pieceT p = pos.GetPiece(sq);
		if (p != EMPTY)
			h ^= z.piece[piece_Color(p)][piece_Type(p)][sq];
	}
	return pos.GetToMove() == BLACK ? h ^ z.blackToMove : h;
}

std::filesystem::path TreeIndex::pathFor(const scidBaseT& base) {
	const auto names = base.getFileNames();
	if (names.empty())
		return {};
	auto path = pathFromUtf8(names[0]);
	path += ".tree";
	return path;
}

errorT TreeIndex::build(const scidBaseT& base, const std::filesystem::path& path,
                        const Progress& progress, unsigned threshold,
                        unsigned maxPly, unsigned deepThreshold) {
	maxPly = std::clamp(maxPly, 1u, kMaxPlyLimit);
	threshold = std::clamp(threshold, 1u, 255u);
	deepThreshold = std::max(deepThreshold, 1u);
	const gamenumT nGames = base.numGames();
	const uint64_t fp = fingerprint(base); // before: a change while building
	                                       // makes the result stale
	const uint64_t stdStartKey = positionKey(Position::getStdStart());

	// Pass 1: count the games reaching each position. Two arrays of saturating
	// counters indexed by different bits of the key (a count-min sketch): a
	// position's real count is never above the smaller of its two counters,
	// so it is exact enough to discard the many positions far below the
	// threshold without keeping one entry per position in memory.
	unsigned bits = 16;
	while (bits < 27 && (uint64_t(1) << bits) < uint64_t(nGames) * maxPly)
		++bits;
	const uint64_t mask = (uint64_t(1) << bits) - 1;
	std::vector<uint8_t> count1(mask + 1), count2(mask + 1);
	auto slot1 = [&](uint64_t k) { return k & mask; };
	auto slot2 = [&](uint64_t k) { return (k >> (64 - bits)) & mask; };
	auto bump = [](uint8_t& c) { c += (c != 255); };
	auto candidate = [&](uint64_t k) {
		return std::min(count1[slot1(k)], count2[slot2(k)]) >= threshold;
	};
	// The same with 32-bit counters, for the few positions reached by enough
	// games for the deeper sequences.
	constexpr unsigned deepBits = 20;
	std::vector<uint32_t> deep1(1u << deepBits), deep2(1u << deepBits);
	auto deepSlot1 = [](uint64_t k) { return k & ((1u << deepBits) - 1); };
	auto deepSlot2 = [](uint64_t k) { return k >> (64 - deepBits); };
	auto deepCandidate = [&](uint64_t k) {
		return std::min(deep1[deepSlot1(k)], deep2[deepSlot2(k)]) >= deepThreshold;
	};

	const size_t total = size_t(nGames) * 2;
	for (gamenumT g = 0; g < nGames; ++g) {
		if ((g & 0xFFF) == 0 && !progress.report(g, total))
			return ERROR_UserCancel;
		forEachMove(base, base.getIndexEntry(g), maxPly, stdStartKey,
		            [&](uint64_t parent, const FullMove*, unsigned) {
			            bump(count1[slot1(parent)]);
			            bump(count2[slot2(parent)]);
			            ++deep1[deepSlot1(parent)];
			            ++deep2[deepSlot2(parent)];
		            });
	}

	// Pass 2: the exact stats of the moves played from the candidates.
	struct EdgeHash {
		size_t operator()(std::pair<uint64_t, uint32_t> const& e) const {
			return e.first ^ (e.second * 0x9E3779B97F4A7C15ULL);
		}
	};
	std::unordered_map<std::pair<uint64_t, uint32_t>, Record, EdgeHash> edges;
	using Sequence = std::pair<uint64_t, std::array<uint32_t, kDepth>>;
	struct SequenceHash {
		size_t operator()(Sequence const& s) const {
			uint64_t h = s.first;
			for (auto m : s.second)
				h = (h ^ m) * 0x9E3779B97F4A7C15ULL;
			return h;
		}
	};
	std::unordered_map<Sequence, DeepRecord, SequenceHash> sequences;
	for (gamenumT g = 0; g < nGames; ++g) {
		if ((g & 0xFFF) == 0 && !progress.report(nGames + g, total))
			return ERROR_UserCancel;
		const IndexEntry* ie = base.getIndexEntry(g);
		forEachMove(base, ie, maxPly, stdStartKey,
		            [&](uint64_t parent, const FullMove* next, unsigned nNext) {
			            if (candidate(parent)) {
				            auto key = std::pair(parent, rawMove(next[0]));
				            addGame(edges.try_emplace(key, Record{}).first->second, ie);
			            }
			            if (deepCandidate(parent)) {
				            Sequence seq{parent, {}};
				            for (unsigned i = 0; i < nNext; ++i)
					            seq.second[i] = rawMove(next[i]);
				            addGame(sequences.try_emplace(seq, DeepRecord{}).first->second,
				                    ie);
			            }
		            });
	}
	count1 = {};
	count2 = {};
	deep1 = {};
	deep2 = {};

	std::vector<Record> records;
	records.reserve(edges.size());
	for (auto& [edge, r] : edges) {
		r.key = edge.first;
		r.move = edge.second;
		records.push_back(r);
	}
	edges = {};
	std::sort(records.begin(), records.end(), [](auto const& a, auto const& b) {
		return a.key != b.key ? a.key < b.key : a.move < b.move;
	});

	// Keep only the positions that really reach the threshold.
	keepFrequent(records, threshold);

	std::vector<DeepRecord> deepRecords;
	deepRecords.reserve(sequences.size());
	for (auto& [seq, r] : sequences) {
		r.key = seq.first;
		std::copy(seq.second.begin(), seq.second.end(), r.moves);
		deepRecords.push_back(r);
	}
	sequences = {};
	std::sort(deepRecords.begin(), deepRecords.end(),
	          [](auto const& a, auto const& b) {
		          if (a.key != b.key)
			          return a.key < b.key;
		          return std::lexicographical_compare(a.moves, a.moves + kDepth,
		                                              b.moves, b.moves + kDepth);
	          });
	keepFrequent(deepRecords, deepThreshold);

	Header header = {};
	std::memcpy(header.magic, kMagic, sizeof kMagic);
	header.version = kVersion;
	header.threshold = threshold;
	header.maxPly = maxPly;
	header.numGames = nGames;
	header.fingerprint = fp;
	header.numRecords = records.size();
	header.deepThreshold = deepThreshold;
	header.numDeepRecords = deepRecords.size();

	auto tmpPath = path;
	tmpPath += ".tmp";
	errorT err = OK;
	{
		FileMap<1 << 16> file;
		err = file.open_path(tmpPath, FMODE_Create);
		if (err == OK)
			err = file.append(reinterpret_cast<const char*>(&header),
			                  sizeof header);
		if (err == OK && !records.empty())
			err = file.append(reinterpret_cast<const char*>(records.data()),
			                  records.size() * sizeof(Record));
		if (err == OK && !deepRecords.empty())
			err = file.append(reinterpret_cast<const char*>(deepRecords.data()),
			                  deepRecords.size() * sizeof(DeepRecord));
		if (auto errClose = file.close(); err == OK)
			err = errClose;
	}
	std::error_code ec;
	if (err == OK) {
		std::filesystem::rename(tmpPath, path, ec);
		if (ec)
			err = ERROR_FileWrite;
	}
	if (err != OK)
		std::filesystem::remove(tmpPath, ec);
	progress.report(1, 1);
	return err;
}

TreeIndex::Status TreeIndex::open(const scidBaseT& base,
                                  const std::filesystem::path& path) {
	file_.close();
	records_ = nullptr;
	nRecords_ = 0;
	deepRecords_ = nullptr;
	nDeepRecords_ = 0;
	if (path.empty())
		return status_ = Status::Unsupported;

	std::error_code ec;
	if (!std::filesystem::exists(path, ec))
		return status_ = Status::None;

	status_ = Status::Stale;
	if (file_.open_path(path, FMODE_ReadOnly) != OK)
		return status_;

	const auto data = file_.view_at(0, file_.size());
	Header header;
	if (data.size() < sizeof header) {
		file_.close();
		return status_;
	}
	std::memcpy(&header, data.data(), sizeof header);
	if (std::memcmp(header.magic, kMagic, sizeof kMagic) != 0 ||
	    header.version != kVersion || header.numGames != base.numGames() ||
	    header.fingerprint != fingerprint(base) ||
	    data.size() != sizeof header + header.numRecords * sizeof(Record) +
	                       header.numDeepRecords * sizeof(DeepRecord)) {
		file_.close();
		return status_;
	}
	records_ = data.data() + sizeof header;
	nRecords_ = header.numRecords;
	deepRecords_ = records_ + nRecords_ * sizeof(Record);
	nDeepRecords_ = header.numDeepRecords;
	return status_ = Status::Active;
}

bool TreeIndex::lookup(const Position& pos, std::vector<TreeNode>& out,
                       int depth) const {
	if (status_ != Status::Active)
		return false;

	const uint64_t key = positionKey(pos);
	const auto first = out.size();
	if (depth <= 1) {
		const auto [lo, hi] = keyRange<Record>(records_, nRecords_, key);
		for (size_t i = lo; i < hi; ++i) {
			const auto r = recordAt<Record>(records_, i);
			addStats(out.emplace_back(std::vector<FullMove>{FullMove(r.move)}), r);
		}
	} else {
		// The stats of a sequence are the sum of the longer ones it begins.
		depth = std::min(depth, kMaxDepth);
		const auto [lo, hi] = keyRange<DeepRecord>(deepRecords_, nDeepRecords_, key);
		std::map<std::array<uint32_t, kDepth>, size_t> nodes;
		for (size_t i = lo; i < hi; ++i) {
			const auto r = recordAt<DeepRecord>(deepRecords_, i);
			std::array<uint32_t, kDepth> prefix = {};
			std::vector<FullMove> moves;
			for (int k = 0; k < depth && r.moves[k]; ++k) {
				prefix[k] = r.moves[k];
				moves.emplace_back(r.moves[k]);
			}
			auto [it, inserted] = nodes.try_emplace(prefix, out.size());
			if (inserted)
				out.emplace_back(std::move(moves));
			addStats(out[it->second], r);
		}
	}
	if (out.size() == first)
		return false;
	std::sort(out.begin() + first, out.end(), TreeNode::cmp_ngames_desc());
	return true;
}
