SET @user1 = UNHEX('018F3E2A1B2C7000AAAA000000000001');
SET @user2 = UNHEX('018F3E2A1B2C7000AAAA000000000002');
SET @user3 = UNHEX('018F3E2A1B2C7000AAAA000000000003');

INSERT INTO User (id, username, email, password, profilePicture)
VALUES (@user1, 'carlos_dev', 'carlos@tempy.com', '$2a$10$hashCarlos123456789012345678901234567890123456',
        'https://cdn.tempy.com/avatars/carlos.webp'),
       (@user2, 'maria_ux', 'maria@tempy.com', '$2a$10$hashMaria1234567890123456789012345678901234567',
        'https://cdn.tempy.com/avatars/maria.webp'),
       (@user3, 'juan_photo', 'juan@tempy.com', '$2a$10$hashJuan12345678901234567890123456789012345678', NULL);

SET @post1 = UNHEX('018F3E2A1B2C7000BBBB000000000001');
SET @post2 = UNHEX('018F3E2A1B2C7000BBBB000000000002');
SET @post3 = UNHEX('018F3E2A1B2C7000BBBB000000000003');

INSERT INTO Post (id, text, deadline, isPublic, isActive, idUser)
VALUES (@post1, 'Primer post sobre desarrollo backend con Spring Boot!', '2025-12-31 23:59:59', TRUE, TRUE, @user1),
       (@post2, 'Diseño UX: tips para mejorar la experiencia de usuario', '2025-11-30 23:59:59', TRUE, TRUE, @user2),
       (@post3, 'Fotografía urbana en Cali — mis mejores tomas del mes', '2025-10-15 23:59:59', FALSE, TRUE, @user3);

SET @content1 = UNHEX('018F3E2A1B2C7000CCCC000000000001');
SET @content2 = UNHEX('018F3E2A1B2C7000CCCC000000000002');
SET @content3 = UNHEX('018F3E2A1B2C7000CCCC000000000003');

INSERT INTO Content (id, link, type, idPost)
VALUES (@content1, 'https://cdn.tempy.com/posts/spring-boot-diagram.png', 'PNG', @post1),
       (@content2, 'https://cdn.tempy.com/posts/ux-tips-infographic.jpeg', 'JPEG', @post2),
       (@content3, 'https://cdn.tempy.com/posts/cali-streets-timelapse.mp4', 'MP4', @post3);

INSERT INTO `Like` (idPost, idUser)
VALUES (@post1, @user2),
       (@post1, @user3),
       (@post2, @user1),
       (@post2, @user3),
       (@post3, @user1);


INSERT INTO Follow (idFollowed, idFollower)
VALUES (@user1, @user2),
       (@user1, @user3),
       (@user2, @user1);
