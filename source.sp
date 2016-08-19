#include <cstrike>
#include <sdktools>
#include <sdkhooks>

#pragma newdecls required
#pragma semicolon 1

#define DEBUG 1

enum MatchState
{
	MatchState_NoMatch,
	MatchState_Querying,
	MatchState_Wating,
	MatchState_Warmup,
	MatchState_Cut,
	MatchState_AfterCut,
	MatchState_Match,
	MatchState_End
};
MatchState g_matchstate = MatchState_NoMatch;
#if !DEBUG
	#define SetMatchState(%1) g_matchstate = %1
#endif

int cutwinner;

StringMap g_cvarbackup = null;

enum AuthState
{
	AuthState_No,
	AuthState_Authed,
	AuthState_Allowed
};

AuthState g_auth[MAXPLAYERS + 1] = {AuthState_No, ...};

Database g_db = null;

public void OnPluginStart()
{
	RegConsoleCmd("sm_pause", Cmd_Pause);
	RegConsoleCmd("sm_unpause", Cmd_Unpause);
	RegConsoleCmd("sm_stay", Cmd_StaySwitch);
	RegConsoleCmd("sm_switch", Cmd_StaySwitch);

	RegAdminCmd("sm_start", Cmd_Start, ADMFLAG_GENERIC);
	RegAdminCmd("sm_esport", Cmd_Debug, ADMFLAG_GENERIC);

	#define HookEvent(%1,%2,%3) PrintToConsoleAll("[SM] HookEvent '" ... %1 ... "' %i", HookEventEx(%1, %2, %3))
	HookEvent("round_start", Event_RoundStart, EventHookMode_Post);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_Post);
	HookEvent("round_prestart", Event_RoundPrestart, EventHookMode_Post);
	// HookEvent("begin_new_match", Event_BeginNewMatch, EventHookMode_PostNoCopy);
	HookEvent("game_start", Event_GameStart, EventHookMode_Post);
	HookEvent("game_init", Event_GameInit, EventHookMode_PostNoCopy);
	HookEvent("game_newmap", Event_GameNewmap, EventHookMode_Post);
	HookEvent("game_end", Event_GameEnd, EventHookMode_Post);
	// HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	HookEvent("cs_win_panel_match", Event_WinPanelMatch, EventHookMode_PostNoCopy);
	// HookEvent("item_equip", Event_ItemEquip, EventHookMode_Pre);
	#undef HookEvent

	Database.Connect(BDConnect, "test");
}

public void BDConnect(Database db, const char[] error, any data)
{
	if (db == null)
		SetFailState("Database connection failed: %s", error);

	db.SetCharset("utf8");
	g_db = db;
}

public void OnMapStart()
{
	// PrintToConsoleAll("[SM] OnMapStart forward");
	// PrintToConsoleAll(" warmup %i", GameRules_GetProp("m_bWarmupPeriod"));

	// TODO: Move to game start event. Or no?
	if (GameRules_GetProp("m_bWarmupPeriod"))
		FindConVar("mp_warmup_pausetimer").BoolValue = true;
}

public void OnMapEnd()
{
	// PrintToConsoleAll("[SM] OnMapEnd forward");
	// PrintToConsoleAll(" g_matchstate %i", g_matchstate);

	if (g_matchstate == MatchState_End)
		SetMatchState(MatchState_NoMatch);
}

public bool OnClientConnect(int client, char[] rejectmsg, int maxlen)
{
	PrintToConsoleAll("[SM] OnClientConnect forward");
	PrintToConsoleAll(" client %i", client);

	switch (g_matchstate) {
		case MatchState_Cut, MatchState_AfterCut, MatchState_Match, MatchState_End: {
			strcopy(rejectmsg, maxlen, "Match started.");
			return false;
		}
	}

	return true;
}

public void OnClientConnected(int client)
{
	PrintToConsoleAll("[SM] OnClientConnected forward");
	PrintToConsoleAll(" client %i", client);
	
	if (g_matchstate == MatchState_NoMatch)
	{
		SetMatchState(MatchState_Querying);

		// TODO: DataBase
		// Quering simulation
		// CreateTimer(0.1, Timer_GetMatch, true);

		char buffer[128];
		GetServerIp(buffer, sizeof(buffer));
		Format(buffer, sizeof(buffer), "SELECT id, team1, team2, map FROM matchs WHERE server_ip = '%s' AND live = 1", buffer);
		g_db.Query(Query_GetMatch, buffer);
	}

	g_auth[client] = AuthState_No;
}

public void Query_GetMatch(Database db, DBResultSet results, const char[] error, any data)
{
	PrintToConsoleAll("[SM] Query_GetMatch callback");

	if (g_matchstate != MatchState_Querying)
		LogError("Result was taken but g_matchstate != MatchState_Querying.");

	if (results == null) {
		for (int i = 1; i <= MaxClients; i++)
			if (IsClientConnected(i))
				KickClient(i, "Can't connect to database");
		SetMatchState(MatchState_NoMatch);
		ThrowError("GetMatch query failed: %s", error);
	}

	PrintToConsoleAll(" RowCount %i", results.RowCount);

	if (results.RowCount) {
		SetMatchState(MatchState_Wating);
		results.FetchRow();
		char map[64] = "de_dust2", curMap[64];
		results.FetchString(3, map, sizeof(map));
		GetCurrentMap(curMap, sizeof(curMap));
		if (!StrEqual(curMap, map))
			ForceChangeLevel(map, "");
		else
			for (int i = 1; i <= MaxClients; i++)
				if (IsClientConnected(i) && g_auth[i] == AuthState_Authed)
					PerfomClientCheck(i);
	}
	else {
		for (int i = 1; i <= MaxClients; i++)
			if (IsClientConnected(i))
				KickClient(i, "It's private tournament server powered by www.esport.re");
		SetMatchState(MatchState_NoMatch);
	}
}

/* public Action Timer_GetMatch(Handle timer, bool result)
{
	PrintToConsoleAll("[SM] Timer_GetMatch timer");

	if (g_matchstate != MatchState_Querying)
		LogError("Result was taken but g_matchstate != MatchState_Querying.");

	if (result) {
		SetMatchState(MatchState_Wating);
		char map[65] = "de_dust2", curMap[65];
		GetCurrentMap(curMap, sizeof(curMap));
		if (!StrEqual(curMap, map))
			ForceChangeLevel(map, "");
		else
			for (int i = 1; i <= MaxClients; i++)
				if (IsClientConnected(i) && g_auth[i] == AuthState_Authed)
					PerfomClientCheck(i);
	}
	else
		for (int i = 1; i <= MaxClients; i++)
			if (IsClientConnected(i))
				KickClient(i, "It's private tournament server powered by www.esport.re");
} */

public void OnClientAuthorized(int client, const char[] auth)
{
	PrintToConsoleAll("[SM] OnClientAuthorized forward");
	PrintToConsoleAll(" client %i", client);
	PrintToConsoleAll(" auth %s", auth);

	if (StrEqual(auth, "BOT"))
		g_auth = AuthState_Allowed;
	else
		switch (g_matchstate) {
			case MatchState_Querying:
				g_auth = AuthState_Authed;
			case MatchState_Wating:
				PerfomClientCheck(client);
		}
}

void PerfomClientCheck(int client)
{
	PrintToConsoleAll("[SM] PerfomClientCheck function");
	PrintToConsoleAll(" client %i", client);

// 	char auth[32];
// 	GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth));
// 	if (StrEqual(auth[8], "1:62167828")) {
// 		g_auth = AuthState_Allowed;
// 		return;
// 	}

	char buffer[128];
	GetClientAuthId(client, AuthId_SteamID64, buffer, sizeof(buffer));
	Format(buffer, sizeof(buffer), "SELECT 1 FROM users WHERE steam_id = '%s'", buffer);
	g_db.Query(Query_CheckAdmin, buffer, client);
}

public void Query_CheckAdmin(Database db, DBResultSet results, const char[] error, int client)
{
	PrintToConsoleAll("[SM] Query_CheckAdmin callback");
	PrintToConsoleAll(" client %i", client);

	if (results == null)
		ThrowError("CheckAdmin query failed: %s", error);

	PrintToConsoleAll(" RowCount %i", results.RowCount);

	if (results.RowCount)
		g_auth = AuthState_Allowed;
		// TODO: Give admin rights
	else
		// TODO: DataBase
		// Quering simulation
		CreateTimer(0.1, Timer_CheckUser, client);
}

public Action Timer_CheckUser(Handle timer, int client)
{
	PrintToConsoleAll("[SM] Timer_CheckUser timer");
	PrintToConsoleAll(" client %i", client);

	char auth[32];
	GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth));
	if (StrEqual(auth, "STEAM_1:1:14535232"))
		g_auth = AuthState_Allowed;
	else
		KickClient(client, "It's private tournament server powered by www.esport.re");
}

public void OnClientPutInServer(int client)
{
	PrintToConsoleAll("[SM] OnClientPutInServer forward");
	PrintToConsoleAll(" client %i", client);

	SDKHook(client, SDKHook_WeaponEquip, Hook_WeaponEquip);
}

//	"round_prestart"			// sent before all other round restart actions
//	{
//	}
public void Event_RoundPrestart(Event event, const char[] name, bool dontBroadcast)
{
	PrintToConsoleAll("[SM] 'round_prestart' event");
	if (g_matchstate == MatchState_Cut) {
		g_cvarbackup = new StringMap();
		SaveSetCvar("mp_maxmoney", "0");
		SaveSetCvar("mp_t_default_secondary", "");
		SaveSetCvar("mp_ct_default_secondary", "");
		SaveSetCvar("mp_freezetime", "0");
		// TODO: Don't work!?
		PrintCenterTextAll("Cut round!");
	}
}

void SaveSetCvar(const char[] convarName, const char[] newValue)
{
	ConVar cvar = FindConVar(convarName);
	char value[32];
	cvar.GetString(value, sizeof(value));
	g_cvarbackup.SetString(convarName, value);
	cvar.SetString(newValue);
}

//	"round_start"
//	{
//		"timelimit"	"long"		// round time limit in seconds
//		"fraglimit"	"long"		// frag limit in seconds
//		"objective"	"string"	// round objective
//	}
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	PrintToConsoleAll("[SM] 'round_start' event");
	PrintToConsoleAll(" timelimit %i", event.GetInt("timelimit"));
	PrintToConsoleAll(" fraglimit %i", event.GetInt("fraglimit"));
	char objective[32];
	event.GetString("objective", objective, sizeof(objective));
	PrintToConsoleAll(" objective %s", objective);
	PrintToConsoleAll(" warmup %i", GameRules_GetProp("m_bWarmupPeriod"));
	PrintToConsoleAll(" g_matchstate %i", g_matchstate);

	switch (g_matchstate) {
		case MatchState_AfterCut:
			PrintToChatAll("Winner team can type !switch for change side or !stay for stay.");
		case MatchState_Cut:
			PrintCenterTextAll("Cut round!");
	}
}

//	"round_end"
//	{
//		"winner"	"byte"		// winner team/user i
//		"reason"	"byte"		// reson why team won
//		"message"	"string"	// end round message 
//		"legacy"	"byte"		// server-generated legacy value
//		"player_count"	"short"		// total number of players alive at the end of round, used for statistics gathering, computed on the server in the event client is in replay when receiving this message
//	}
public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	PrintToConsoleAll("[SM] 'round_end' event");
	PrintToConsoleAll(" g_matchstate %i", g_matchstate);

	switch (g_matchstate) {
		case MatchState_Cut: {
			SetMatchState(MatchState_AfterCut);
			LoadSetCvar("mp_maxmoney");
			LoadSetCvar("mp_t_default_secondary");
			LoadSetCvar("mp_ct_default_secondary");
			LoadSetCvar("mp_freezetime");
			delete g_cvarbackup;
			ServerCommand("mp_pause_match");
			cutwinner = event.GetInt("winner");
		}
	}
}

void LoadSetCvar(const char[] convarName)
{
	ConVar cvar = FindConVar(convarName);
	char value[32];
	g_cvarbackup.GetString(convarName, value, sizeof(value));
	cvar.SetString(value);
}

//	// Fired when a match ends or is restarted
//	"begin_new_match"
//	{
//	}
public void Event_BeginNewMatch(Event event, const char[] name, bool dontBroadcast)
{
	PrintToConsoleAll("[SM] 'begin_new_match' event");
	PrintToConsoleAll(" g_matchstate %i", g_matchstate);
}

//	"game_start"				// a new game starts
//	{
//		"roundslimit"	"long"		// max round
//		"timelimit"	"long"		// time limit
//		"fraglimit"	"long"		// frag limit
//		"objective"	"string"	// round objective
//	}
public void Event_GameStart(Event event, const char[] name, bool dontBroadcast)
{
	PrintToConsoleAll("[SM] 'game_start' event");
	PrintToConsoleAll(" roundslimit %i", event.GetInt("roundslimit"));
	PrintToConsoleAll(" timelimit %i", event.GetInt("timelimit"));
	PrintToConsoleAll(" fraglimit %i", event.GetInt("fraglimit"));
	char objective[32];
	event.GetString("objective", objective, sizeof(objective));
	PrintToConsoleAll(" objective %s", objective);

//	SetMatchState(MatchState_Wating);
//	if (GameRules_GetProp("m_bWarmupPeriod"))
//		FindConVar("mp_warmup_pausetimer").BoolValue = true;
}

//	"game_init"				// sent when a new game is started
//	{
//	}
public void Event_GameInit(Event event, const char[] name, bool dontBroadcast)
{
	PrintToConsoleAll("[SM] 'game_init' event");
}

//	"game_newmap"				// send when new map is completely loaded
//	{
//		"mapname"	"string"	// map name
//	}
public void Event_GameNewmap(Event event, const char[] name, bool dontBroadcast)
{
	PrintToConsoleAll("[SM] 'game_init' event");
	char mapname[32];
	event.GetString("mapname", mapname, sizeof(mapname));
	PrintToConsoleAll(" mapname %s", mapname);
}

//	"game_end"				// a game ended
//	{
//		"winner"	"byte"		// winner team/user id
//	}
public void Event_GameEnd(Event event, const char[] name, bool dontBroadcast)
{
	PrintToConsoleAll("[SM] 'game_end' event");
	PrintToConsoleAll(" winner %i", event.GetInt("winner"));
	PrintToConsoleAll(" g_matchstate %i", g_matchstate);

	if (g_matchstate == MatchState_Match)
		SetMatchState(MatchState_End);
}

//	"player_spawn"				// player spawned in game
//	{
//		"userid"	"short"		// user ID on server
//		"teamnum"		"short"
//	}
public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	PrintToConsoleAll("[SM] 'player_spawn' event");
	PrintToConsoleAll(" userid %i", event.GetInt("userid"));
	PrintToConsoleAll(" teamnum %i", event.GetInt("teamnum"));
}

public void Event_WinPanelMatch(Event event, const char[] name, bool dontBroadcast)
{
	PrintToConsoleAll("[SM] 'cs_win_panel_match' event");

	SetMatchState(MatchState_End);

	PrintToConsoleAll("[SM] T score %i", CS_GetTeamScore(CS_TEAM_T));
	PrintToConsoleAll("[SM] CT score %i", CS_GetTeamScore(CS_TEAM_CT));
}

//	"item_equip"
//	{
//		"userid"		"short"
//		"item"			"string"	// either a weapon such as 'tmp' or 'hegrenade', or an item such as 'nvgs'
//		"canzoom"		"bool"
//		"hassilencer"	"bool"
//		"issilenced"	"bool"
//		"hastracers"	"bool"
//		"weptype"		"short"
//				//WEAPONTYPE_UNKNOWN		=	-1
//				//WEAPONTYPE_KNIFE			=	0	
//				//WEAPONTYPE_PISTOL			=	1
//				//WEAPONTYPE_SUBMACHINEGUN	=	2
//				//WEAPONTYPE_RIFLE			=	3
//				//WEAPONTYPE_SHOTGUN		=	4
//				//WEAPONTYPE_SNIPER_RIFLE	=	5
//				//WEAPONTYPE_MACHINEGUN		=	6
//				//WEAPONTYPE_C4				=	7
//				//WEAPONTYPE_GRENADE		=	8
//				//
//		"ispainted"	"bool"
//	}
public Action Event_ItemEquip(Event event, const char[] name, bool dontBroadcast)
{
	PrintToConsoleAll("[SM] 'item_equip' event");
	char item[32];
	event.GetString("item", item, sizeof(item));
	PrintToConsoleAll(" item %s", item);

	return Plugin_Continue;
}

public Action Hook_WeaponEquip(int client, int weapon)
{
	PrintToConsoleAll("[SM] 'Weapon Equip' hook");
	PrintToConsoleAll(" client %i", client);
	PrintToConsoleAll(" weapon %i", weapon);

	if (g_matchstate == MatchState_Cut) {
		char classname[32];
		GetEntityClassname(weapon, classname, sizeof(classname));
		if (StrEqual(classname, "weapon_c4")) {
			AcceptEntityInput(weapon, "Kill");
			return Plugin_Stop;
		}
	}

	return Plugin_Continue;
}

stock void PrintToConsoleAll(const char[] format, any ...)
{
	char buffer[1024];

	// ToServer
	SetGlobalTransTarget(LANG_SERVER);
	VFormat(buffer, sizeof(buffer), format, 2);
	PrintToServer("%s", buffer);

	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i)) {
			SetGlobalTransTarget(i);
			VFormat(buffer, sizeof(buffer), format, 2);
			PrintToConsole(i, "%s", buffer);
		}
}

/// Usage: sm_pause
public Action Cmd_Pause(int client, int args)
{
	// TODO: Pause command
	ReplyToCommand(client, "sm_pause is not created yet.");

	return Plugin_Handled;
}

/// Usage: sm_unpause
public Action Cmd_Unpause(int client, int args)
{
	// TODO: Unpause command
	ReplyToCommand(client, "sm_unpause is not created yet.");

	return Plugin_Handled;
}

/// Usage: sm_start [skip]
public Action Cmd_Start(int client, int args)
{
	// TODO: Start command
	ReplyToCommand(client, "sm_start is not finished yet.");

	if (g_matchstate != MatchState_Wating) {
		ReplyToCommand(client, "Server not in wating state."); // Debug
		return Plugin_Handled;
	}

	if (args > 1) {
		ReplyToCommand(client, "Usage: sm_start [skip]");
		return Plugin_Handled;
	}

	g_matchstate = MatchState_Cut;
	char arg[128];
	GetCmdArg(1, arg, sizeof(arg));
	if (StrEqual(arg, "skip")) {
		ServerCommand("mp_warmup_end");
		// g_matchstate = MatchState_Cut;
	}
	else {
		FindConVar("mp_warmup_pausetimer").BoolValue = false;
		// g_matchstate = MatchState_Warmup;
	}

	return Plugin_Handled;
}

/// Usage: sm_stay/sm_switch
public Action Cmd_StaySwitch(int client, int args)
{
	// TODO: Stay/Switch command
	char cmd[12];
	GetCmdArg(0, cmd, sizeof(cmd));
	ReplyToCommand(client, "%s is not finished yet.", cmd);

	if (g_matchstate != MatchState_AfterCut || !client)
		return Plugin_Handled;

	if (GetClientTeam(client) != cutwinner) {
		ReplyToCommand(client, "Only winner team can choose.");
		return Plugin_Handled;
	}

	ServerCommand("mp_unpause_match");
	g_matchstate = MatchState_Match;
	if (StrEqual(cmd, "sm_switch"))
		ServerCommand("mp_swapteams");
	else
		FindConVar("mp_restartgame").IntValue = 1;

	return Plugin_Handled;
}

/// Usage: sm_esport <type>
public Action Cmd_Debug(int client, int args)
{
	if (args < 1) {
		ReplyToCommand(client, "Usage: sm_esport <type>");
		return Plugin_Handled;
	}

	char arg[12];
	GetCmdArg(1, arg, sizeof(arg));
	switch (StringToInt(arg)) {
		case 0:
			ReplyToCommand(client, "MatchState: %i", g_matchstate);
	}

	return Plugin_Handled;
}

int GetServerIp(char[] buffer, int maxlength)
{
	int hostip = FindConVar("hostip").IntValue;
	return FormatEx(buffer, maxlength, "%i.%i.%i.%i:%i", hostip >> 24 & 0xFF, hostip >> 16 & 0xFF, hostip >> 8 & 0xFF, hostip & 0xFF, FindConVar("hostport").IntValue);
}

#if DEBUG
void SetMatchState(MatchState matchstate)
{
	PrintToConsoleAll("[SM] MatchState: %i", matchstate);
	g_matchstate = matchstate;
}
#endif
