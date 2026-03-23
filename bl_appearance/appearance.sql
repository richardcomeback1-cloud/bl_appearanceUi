-- Appearance data is now stored in `users.skin` for ESX compatibility.
-- Keep this file for the outfits table used by bl_appearance.

CREATE TABLE IF NOT EXISTS `outfits` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `player_id` varchar(100) NOT NULL,
  `label` varchar(100) NOT NULL,
  `outfit` longtext DEFAULT NULL,
  `jobname` varchar(50) DEFAULT NULL,
  `jobrank` int(2) NOT NULL DEFAULT 0,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
