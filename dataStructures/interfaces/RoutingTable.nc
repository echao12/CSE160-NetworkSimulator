#include "../../includes/route.h"

interface RoutingTable {
    command void mergeRoute(Route route);
    command void addNeighbor(uint16_t neighborID);
    command void updateTable(Route* newRoutes, uint16_t numNewRoutes);
    command uint16_t lookup(uint16_t destination);
    command void printTable();
}