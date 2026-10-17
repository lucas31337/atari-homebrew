# Rainstorm

## Welcome Screen

The Welcome Screen will show the name and author and have one option -- "START" (fire button).

## Intro

After the Welcome Screen, we'll start the Intro sequence. The title will disappear, a blue sky over a grassy field will appear, white clouds start to roll in slowly and then turn grey. Then lightning starts to appear in the clouds. Then raindrops start to fall, and some lightning strikes the ground.

## Main game

The Main Game scene starts just after the intro, with stormy clouds and grass, and three trees. Each tree will have a height of 2, 3, or 4. On level 1, the trees are all 4's. Lightning strikes the highest object in the game (per physics). A tree of size 4, when struck, produces 4 blocks of wood that the player can pick up. The player is a person that can walk left and right, pick up blocks of wood, and build a tower of wood.

the minimum players:1

When all the trees are gone you will have a seed. To plant the seed press the fire button.

### Rules (as implemented)

- **Music.** Pressing START on the title starts the song (music/glafouk - miniblast.ttt, Glafouk's "Miniblast"), which loops through the intro and the whole game. The bolt hitting the player cuts it off; the ROUND and GAME OVER screens play their own tunes; the title screen is silent.
- **Lightning target.** Heights are counted in blocks: a tree counts its trunk blocks (the canopy does not count), a wood pile counts its logs, the tower counts its blocks, and the player counts 2 (3 from 6 lines up in a jump, 4 at the top). The tallest object is struck. Ties go to the tower first, then the leftmost tree, then the leftmost pile; the player loses every tie. So on level 1 (trees of 4) the tower is hit as soon as it reaches 4 blocks, and once the trees are gone the piles start burning unless a new tree is planted to draw the lightning.
- **Struck tree** becomes a pile of that many wood blocks at its base (a pile holds at most 8). **Struck tower** loses 2 blocks. **Struck pile** loses 2 logs.
- **Strike interval** by level (frames): 240, 210, 180, 150, 120, 90, 90, 90.
- **Player.** Joystick left/right walks. Joystick up jumps 2 blocks high (about 20 frames in the air; you can keep walking, and holding up bounces). FIRE with empty hands picks up a block from a pile within reach; FIRE while holding a block at the right edge (the tower zone) stacks it on the tower.
- **Seed.** When no trees are standing and the player's hands are empty, the player holds a seed. FIRE plants it in the nearest empty slot; the new tree gets a random height (2-4; 4 on level 1).
- **Rounds and the clock.** Round 1 has a 30-second countdown; every round gets 30 seconds more (60, 90, then capped at 99). When the clock runs out the next round starts: a ROUND screen with the round number shows for 2 seconds while the round jingle (music/second round.ttt) plays, then play resumes with new trees, empty tower and piles, faster lightning. Building the tower up to the goal (4 + round, max 8 blocks) also ends the round early. The status line shows round, tower height and seconds left.
- **Game over.** When the player is the tallest object, the bolt hits them. Standing behind or beside a tree, pile or tower that gets struck is safe: it takes the hit for you. Watch out when little is left standing, and do not jump near a strike (a jump makes you up to 4 blocks tall). The scene freezes with the bolt for 1.5 seconds, then a GAME OVER screen with the round reached appears and the game-over jingle (music/game over - first revision.ttt) plays once; FIRE returns to the title.
