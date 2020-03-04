#define MAX_ROUTING_TABLE_SIZE 256
#define MAX_ROUTE_TTL 120

typedef struct {
    uint16_t destination;
    uint16_t nextHop;
    uint16_t cost;
    uint16_t TTL;  // what to do with this?
} Route;

interface RoutingTable {
    command void mergeRoute(Route route);
    command void addNeighbor(uint16_t neighborID);
    command void updateTable(Route* newRoutes, uint16_t numNewRoutes);
    command uint16_t lookup(uint16_t destination);
    command void printTable();
}