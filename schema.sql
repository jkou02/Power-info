-- schema.sql
-- Definición de la estructura para el registro de cortes de energía

CREATE TABLE IF NOT EXISTS cortes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    inicio DATETIME NOT NULL,
    fin DATETIME NOT NULL,
    duracion_seg INTEGER NOT NULL,
    creado_en DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Índice para acelerar las consultas de gráficos por fecha
CREATE INDEX IF NOT EXISTS idx_cortes_inicio ON cortes(inicio);