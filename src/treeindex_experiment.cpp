// EXPERIMENT (branch experiment/tree-index-measurements only, not for merge).
// Measures how large a precomputed, sorted tree index (OBR-like) would be for
// a database: how many positions within the first maxPly plies are reached by
// at least 5/10/20 games, and how many (position, move) entries those carry.
//
//   sc_tree expopen <SCID5|SCID4> filename   -> baseId (opened read-only)
//   sc_tree expstats baseId maxPly           -> prints report, returns it

#include "dbasepool.h"
#include "gameview.h"
#include "misc.h"
#include "scidbase.h"
#include "ui.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <random>
#include <string>
#include <vector>

namespace {

uint64_t zob[2][8][64];
uint64_t zobBlackToMove;

void initZobrist() {
	std::mt19937_64 rng(20261113);
	for (auto& c : zob)
		for (auto& p : c)
			for (auto& sq : p)
				sq = rng();
	zobBlackToMove = rng();
}

// Same identity as Scid's tree: board + side to move (no castling/ep rights).
uint64_t hashStart() {
	const Position& pos = Position::getStdStart();
	uint64_t h = 0;
	for (squareT sq = 0; sq < 64; ++sq) {
		pieceT p = pos.GetPiece(sq);
		if (p != EMPTY)
			h ^= zob[piece_Color(p)][piece_Type(p)][sq];
	}
	return h;
}

// Returns false on a null move (the position stops being meaningful).
bool applyMove(uint64_t& h, colorT c, FullMove m) {
	const squareT from = m.getFrom(), to = m.getTo();
	if (from == to)
		return false;
	if (m.isCastle()) { // from = king square, to = rook square
		const bool kingSide = to > from;
		const squareT kTo = square_Relative(c, kingSide ? G1 : C1);
		const squareT rTo = square_Relative(c, kingSide ? F1 : D1);
		h ^= zob[c][KING][from] ^ zob[c][KING][kTo] ^ zob[c][ROOK][to] ^
		     zob[c][ROOK][rTo];
	} else {
		const pieceT pt = m.getPiece();
		h ^= zob[c][pt][from];
		if (const pieceT cap = m.getCaptured()) {
			squareT capSq = to;
			if (m.isEnpassant())
				capSq = (c == WHITE) ? to - 8 : to + 8;
			h ^= zob[1 - c][cap][capSq];
		}
		h ^= zob[c][m.isPromo() ? m.getPromo() : pt][to];
	}
	h ^= zobBlackToMove;
	return true;
}

using Clock = std::chrono::steady_clock;
double secondsSince(Clock::time_point t0) {
	return std::chrono::duration<double>(Clock::now() - t0).count();
}

// Calls fn(parentHash, childHash) for every ply of the main line, up to maxPly.
template <typename Fn>
long long forEachGame(const scidBaseT& base, int maxPly, const char* label,
                      Fn fn) {
	const uint64_t start = hashStart();
	long long skipped = 0;
	const auto t0 = Clock::now();
	for (gamenumT g = 0, n = base.numGames(); g < n; ++g) {
		if (g % 1000000 == 0 && g)
			std::fprintf(stderr, "  %s: %u/%u games, %.0fs\n", label, g, n,
			             secondsSince(t0));
		const IndexEntry* ie = base.getIndexEntry(g);
		if (ie->GetStartFlag()) { // non-standard start: not part of the tree
			++skipped;
			continue;
		}
		auto gv = base.getGame(ie);
		uint64_t h = start;
		colorT c = WHITE;
		int ply = 0;
		fn(g, 0, h, ply);
		gv.mainLine([&](FullMove m) {
			const uint64_t parent = h;
			if (!applyMove(h, c, m))
				return false;
			c = 1 - c;
			fn(g, parent, h, ++ply);
			return ply < maxPly;
		});
	}
	return skipped;
}

} // namespace

UI_res_t sc_tree_expopen(UI_extra_t, UI_handle_t ti, int argc, const char** argv) {
	if (argc != 4)
		return UI_Result(ti, ERROR_BadArg,
		                 "Usage: sc_tree expopen <SCID5|SCID4> filename");
	auto dbase = DBasePool::getFreeSlot();
	if (!dbase)
		return UI_Result(ti, ERROR_Full);
	errorT err = dbase->open(argv[2], FMODE_ReadOnly, argv[3],
	                         UI_CreateProgress(ti));
	if (err != OK && err != ERROR_NameDataLoss)
		return UI_Result(ti, err);
	return UI_Result(ti, OK, DBasePool::switchCurrent(dbase));
}

UI_res_t sc_tree_expstats(UI_extra_t, UI_handle_t ti, int argc, const char** argv) {
	if (argc != 4)
		return UI_Result(ti, ERROR_BadArg,
		                 "Usage: sc_tree expstats baseId maxPly");
	const scidBaseT* base = DBasePool::getBase(strGetUnsigned(argv[2]));
	const int maxPly = strGetInteger(argv[3]);
	if (!base || maxPly < 1)
		return UI_Result(ti, ERROR_BadArg);
	initZobrist();
	const int thresholds[] = {5, 10, 20};

	// Pass 1: one hash per (game, distinct position), then sort and count.
	auto t0 = Clock::now();
	std::vector<uint64_t> occ;
	occ.reserve(size_t(base->numGames()) * (maxPly + 1));
	std::vector<uint64_t> local;
	gamenumT cur = 0;
	auto flushGame = [&] {
		std::sort(local.begin(), local.end());
		local.erase(std::unique(local.begin(), local.end()), local.end());
		occ.insert(occ.end(), local.begin(), local.end());
		local.clear();
	};
	const long long skipped = forEachGame(
	    *base, maxPly, "pass 1",
	    [&](gamenumT g, uint64_t, uint64_t child, int) {
		    if (g != cur) {
			    flushGame();
			    cur = g;
		    }
		    local.push_back(child);
	    });
	flushGame();
	const double tPass1 = secondsSince(t0);
	const size_t occurrences = occ.size();

	t0 = Clock::now();
	std::sort(occ.begin(), occ.end());
	const double tSort = secondsSince(t0);

	// Keep only positions reached by >= 5 games, with their game count.
	std::vector<std::pair<uint64_t, uint32_t>> qual;
	size_t distinct = 0, single = 0;
	size_t atLeast[3] = {0, 0, 0};
	size_t exact[5] = {0, 0, 0, 0, 0}; // positions with exactly 1..4 games
	size_t occAtLeast[3] = {0, 0, 0};  // game-visits landing on them
	for (size_t i = 0; i < occ.size();) {
		size_t j = i;
		while (j < occ.size() && occ[j] == occ[i])
			++j;
		const size_t cnt = j - i;
		++distinct;
		single += (cnt == 1);
		for (int k = 0; k < 3; ++k)
			if (cnt >= size_t(thresholds[k])) {
				++atLeast[k];
				occAtLeast[k] += cnt;
			}
		if (cnt < 5)
			++exact[cnt];
		if (cnt >= 5)
			qual.emplace_back(occ[i], uint32_t(cnt));
		i = j;
	}
	std::vector<uint64_t>().swap(occ); // free before pass 2

	// Self-check against Scid's own tree: games reaching 1.e4 and 1.e4 c5.
	auto countOf = [&](uint64_t h) -> uint32_t {
		auto it = std::lower_bound(
		    qual.begin(), qual.end(), h,
		    [](auto const& e, uint64_t v) { return e.first < v; });
		return (it != qual.end() && it->first == h) ? it->second : 0;
	};
	uint64_t hE4 = hashStart();
	applyMove(hE4, WHITE, FullMove(WHITE, E2, E4, PAWN));
	uint64_t hE4c5 = hE4;
	applyMove(hE4c5, BLACK, FullMove(BLACK, C7, C5, PAWN));
	const uint32_t cntE4 = countOf(hE4), cntE4c5 = countOf(hE4c5);

	// Pass 2: distinct (position, move) edges leaving a qualifying position.
	// Bucket of the parent's game count lives in the top 2 bits of the key.
	t0 = Clock::now();
	std::vector<uint64_t> edges;
	// Per ply: game-visits, and how many land on a position with >=5/10/20.
	std::vector<std::array<size_t, 4>> perPly(maxPly + 1);
	auto compact = [&] {
		std::sort(edges.begin(), edges.end());
		edges.erase(std::unique(edges.begin(), edges.end()), edges.end());
	};
	forEachGame(*base, maxPly, "pass 2",
	            [&](gamenumT, uint64_t parent, uint64_t child, int ply) {
		            if (ply == 0)
			            return;
		            const uint32_t childCnt = countOf(child);
		            auto& pp = perPly[ply];
		            ++pp[0];
		            pp[1] += (childCnt >= 5);
		            pp[2] += (childCnt >= 10);
		            pp[3] += (childCnt >= 20);
		            auto it = std::lower_bound(
		                qual.begin(), qual.end(), parent,
		                [](auto const& e, uint64_t v) { return e.first < v; });
		            if (it == qual.end() || it->first != parent)
			            return;
		            const uint64_t bucket = it->second >= 20   ? 2
		                                    : it->second >= 10 ? 1
		                                                       : 0;
		            uint64_t key = (parent * 0x9E3779B97F4A7C15ULL) ^ child;
		            key = (key & ~(3ULL << 62)) | (bucket << 62);
		            edges.push_back(key);
		            if (edges.size() >= 100000000)
			            compact();
	            });
	compact();
	size_t edgesAtLeast[3] = {edges.size(), 0, 0};
	for (uint64_t e : edges) {
		const auto b = e >> 62;
		edgesAtLeast[1] += (b >= 1);
		edgesAtLeast[2] += (b >= 2);
	}
	const double tPass2 = secondsSince(t0);

	char buf[8192];
	int len = std::snprintf(
	    buf, sizeof buf,
	    "games=%u skipped_nonstd_start=%lld maxPly=%d\n"
	    "position_occurrences=%zu distinct_positions=%zu "
	    "positions_with_1_game=%zu\n"
	    "below 5: exactly 1 game=%zu, 2=%zu, 3=%zu, 4=%zu\n"
	    "selfcheck: games after 1.e4=%u, after 1.e4 c5=%u\n",
	    base->numGames(), skipped, maxPly, occurrences, distinct, single,
	    exact[1], exact[2], exact[3], exact[4], cntE4, cntE4c5);
	for (int k = 0; k < 3; ++k)
		len += std::snprintf(
		    buf + len, sizeof buf - len,
		    "threshold %2d: positions >=%d games: %zu (<%d: %zu), "
		    "index entries (position,move): %zu, est. size ~%.0f MB @40B, "
		    "game-visits covered %.1f%%\n",
		    thresholds[k], thresholds[k], atLeast[k], thresholds[k],
		    distinct - atLeast[k], edgesAtLeast[k],
		    edgesAtLeast[k] * 40.0 / 1e6, 100.0 * occAtLeast[k] / occurrences);
	len += std::snprintf(buf + len, sizeof buf - len,
	                     "ply    visits  in-index%% (>=5 >=10 >=20)\n");
	for (int p = 1; p <= maxPly; ++p) {
		const auto& pp = perPly[p];
		if (pp[0] == 0)
			continue;
		len += std::snprintf(buf + len, sizeof buf - len,
		                     "%3d %9zu  %5.1f %5.1f %5.1f\n", p, pp[0],
		                     100.0 * pp[1] / pp[0], 100.0 * pp[2] / pp[0],
		                     100.0 * pp[3] / pp[0]);
	}
	std::snprintf(buf + len, sizeof buf - len,
	              "time: pass1 %.1fs, sort %.1fs, pass2 %.1fs\n", tPass1, tSort,
	              tPass2);
	std::fputs(buf, stdout);
	return UI_Result(ti, OK, std::string(buf));
}
