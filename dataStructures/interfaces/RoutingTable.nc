#include "../../includes/route.h"

interface RoutingTable {
    command void mergeRoute(Route route);
    command void updateTable(Route* newRoutes, uint16_t numNewRoutes);
    command Route* getTable();
    command uint16_t lookup(uint16_t destination);
    command uint16_t size();
    command void printTable();
}