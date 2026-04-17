CREATE TABLE User
(
    id             BINARY(16) PRIMARY KEY,
    username       VARCHAR(50) UNIQUE NOT NULL,
    email          VARCHAR(50) UNIQUE NOT NULL,
    password       VARCHAR(70)        NOT NULL,
    profilePicture VARCHAR(255)       NULL,
    createdAt      TIMESTAMP          NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updatedAt      TIMESTAMP          NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE Post
(
    id        BINARY(16) PRIMARY KEY,
    text      VARCHAR(255) NOT NULL,
    deadline  TIMESTAMP    NOT NULL,
    isPublic  BOOLEAN      NOT NULL DEFAULT TRUE,
    isActive  BOOLEAN      NOT NULL DEFAULT TRUE,
    idUser    BINARY(16)   NOT NULL,
    createdAt TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updatedAt TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fkUserPost FOREIGN KEY (idUser)
        REFERENCES User (id) ON DELETE CASCADE
);

CREATE TABLE Content
(
    id        BINARY(16) PRIMARY KEY,
    link      VARCHAR(255)                                      NOT NULL,
    type      ENUM ('GIF', 'MP4', 'JPEG', 'JPG', 'PNG', 'WEBP') NOT NULL,
    idPost    BINARY(16)                                        NOT NULL,
    createdAt TIMESTAMP                                         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updatedAt TIMESTAMP                                         NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fkPostContent FOREIGN KEY (idPost)
        REFERENCES Post (id) ON DELETE CASCADE
);

-- 'Like' is a keyword, use backticks when referencing this table
CREATE TABLE `Like`
(
    idPost    BINARY(16) NOT NULL,
    idUser    BINARY(16) NOT NULL,
    createdAt TIMESTAMP  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (idPost, idUser),
    CONSTRAINT fkLikePost FOREIGN KEY (idPost) REFERENCES Post (id) ON DELETE CASCADE,
    CONSTRAINT fkLikeUser FOREIGN KEY (idUser) REFERENCES User (id) ON DELETE CASCADE
);

CREATE TABLE Follow
(
    idFollowed BINARY(16) NOT NULL,
    idFollower BINARY(16) NOT NULL,
    createdAt  TIMESTAMP  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (idFollowed, idFollower),
    CONSTRAINT fkFollowed FOREIGN KEY (idFollowed) REFERENCES User (id) ON DELETE CASCADE,
    CONSTRAINT fkFollower FOREIGN KEY (idFollower) REFERENCES User (id) ON DELETE CASCADE,
    CONSTRAINT checkNotSelfFollow CHECK (idFollowed <> idFollower)
);

CREATE INDEX idxPostIsActive ON Post (isActive);
CREATE INDEX idxPostDeadline ON Post (deadline);
CREATE INDEX idxUserUsername ON User (username);

CREATE INDEX idxPostIdUser ON Post (idUser);
CREATE INDEX idxFollowerIdx ON Follow (idFollower);
CREATE INDEX idxLikeUser ON `Like` (idUser);
